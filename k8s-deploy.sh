#!/bin/bash
set -x
set -e

HTTP_SERVER=192.168.56.1:8000
KUBE_HA=true

KUBE_REPO_PREFIX=gcr.io/google_containers
KUBE_ETCD_IMAGE=quay.io/coreos/etcd:v3.0.17

root=$(id -u)
if [ "$root" -ne 0 ] ;then
    echo must run as root
    exit 1
fi

kube::install_docker()
{
    set +e
    docker info> /dev/null 2>&1
    i=$?
    set -e
    if [ $i -ne 0 ]; then
        curl -L http://$HTTP_SERVER/rpms/docker.tar.gz > /tmp/docker.tar.gz
        tar zxf /tmp/docker.tar.gz -C /tmp
        yum localinstall -y /tmp/docker/*.rpm
        systemctl enable docker.service && systemctl start docker.service
        kube::config_docker
    fi
    echo docker has been installed
    rm -rf /tmp/docker /tmp/docker.tar.gz
}

kube::config_docker()
{
    setenforce 0 > /dev/null 2>&1 && sed -i -e 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config

    sysctl -w net.bridge.bridge-nf-call-iptables=1
    sysctl -w net.bridge.bridge-nf-call-ip6tables=1
cat <<EOF >>/etc/sysctl.conf
    net.bridge.bridge-nf-call-ip6tables = 1
    net.bridge.bridge-nf-call-iptables = 1
EOF

    sed -i -e 's/DOCKER_STORAGE_OPTIONS=/DOCKER_STORAGE_OPTIONS="-s overlay --selinux-enabled=false"/g' /etc/sysconfig/docker-storage

    systemctl daemon-reload && systemctl restart docker.service
}

kube::load_images()
{
    mkdir -p /tmp/k8s

    images=(
        kube-apiserver-amd64_v1.6.2
        kube-controller-manager-amd64_v1.6.2
        kube-scheduler-amd64_v1.6.2
        kube-proxy-amd64_v1.6.2
        pause-amd64_3.0
        k8s-dns-dnsmasq-nanny-amd64_1.14.1
        k8s-dns-kube-dns-amd64_1.14.1
        k8s-dns-sidecar-amd64_1.14.1
        etcd_v3.0.17
        flannel-amd64_v0.7.1
    )

    for i in "${!images[@]}"; do
        ret=$(docker images | awk 'NR!=1{print $1"_"$2}'| grep $KUBE_REPO_PREFIX/${images[$i]} | wc -l)
        if [ $ret -lt 1 ];then
            curl -L http://$HTTP_SERVER/images/${images[$i]}.tar > /tmp/k8s/${images[$i]}.tar
            docker load < /tmp/k8s/${images[$i]}.tar
        fi
    done

    rm /tmp/k8s* -rf
}

kube::install_k8s()
{
    set +e
    which kubeadm > /dev/null 2>&1
    i=$?
    set -e
    if [ $i -ne 0 ]; then
        curl -L http://$HTTP_SERVER/rpms/k8s.tar.gz > /tmp/k8s.tar.gz
        tar zxf /tmp/k8s.tar.gz -C /tmp
        yum localinstall -y  /tmp/k8s/*.rpm
        rm -rf /tmp/k8s*
        systemctl enable kubelet.service && systemctl start kubelet.service && rm -rf /etc/kubernetes
    fi
}

kube::config_firewalld()
{
    systemctl disable firewalld && systemctl stop firewalld
    # iptables -A IN_public_allow -p tcp -m tcp --dport 9898 -m conntrack --ctstate NEW -j ACCEPT
    # iptables -A IN_public_allow -p tcp -m tcp --dport 6443 -m conntrack --ctstate NEW -j ACCEPT
    # iptables -A IN_public_allow -p tcp -m tcp --dport 10250 -m conntrack --ctstate NEW -j ACCEPT
}

kube::get_env()
{
  HA_STATE=$1
  [ $HA_STATE == "MASTER" ] && HA_PRIORITY=200 || HA_PRIORITY=`expr 200 - ${RANDOM} / 1000 + 1`
  KUBE_VIP=$(echo $2 |awk -F= '{print $2}')
  VIP_PREFIX=$(echo ${KUBE_VIP} | cut -d . -f 1,2,3)
  ###dhcp和static地址的不同取法
  VIP_INTERFACE=$(ip addr show | grep ${VIP_PREFIX} | awk -F 'dynamic' '{print $2}' | head -1)
  [ -z ${VIP_INTERFACE} ] && VIP_INTERFACE=$(ip addr show | grep ${VIP_PREFIX} | awk -F 'global' '{print $2}' | head -1)
  ###
  LOCAL_IP=$(ip addr show | grep ${VIP_PREFIX} | awk -F / '{print $1}' | awk -F ' ' '{print $2}' | head -1)
  MASTER_NODES=$(echo $3 | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
  MASTER_NODES_NO_LOCAL_IP=$(echo "${MASTER_NODES}" | sed -e 's/'${LOCAL_IP}'//g')
}

kube::install_keepalived()
{
    kube::get_env $@
    set +e
    which keepalived > /dev/null 2>&1
    i=$?
    set -e
    if [ $i -ne 0 ]; then
        ip addr add ${KUBE_VIP}/32 dev ${VIP_INTERFACE}
        curl -L http://$HTTP_SERVER/rpms/keepalived.tar.gz > /tmp/keepalived.tar.gz
        tar zxf /tmp/keepalived.tar.gz -C /tmp
        yum localinstall -y  /tmp/keepalived/*.rpm
        rm -rf /tmp/keepalived*
        systemctl enable keepalived.service && systemctl start keepalived.service
        kube::config_keepalived
    fi
}

kube::config_keepalived()
{
  echo "gen keepalived configuration"
cat <<EOF >/etc/keepalived/keepalived.conf
global_defs {
   router_id LVS_k8s
}

vrrp_script CheckK8sMaster {
    script "curl -k https://127.0.0.1:6443/api"
    interval 3
    timeout 9
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state ${HA_STATE}
    interface ${VIP_INTERFACE}
    virtual_router_id 61
    priority ${HA_PRIORITY}
    advert_int 1
    mcast_src_ip ${LOCAL_IP}
    nopreempt
    authentication {
        auth_type PASS
        auth_pass 378378
    }
    unicast_peer {
        ${MASTER_NODES_NO_LOCAL_IP}
    }
    virtual_ipaddress {
        ${KUBE_VIP}
    }
    track_script {
        CheckK8sMaster
    }
}

EOF
  modprobe ip_vs
  systemctl daemon-reload && systemctl restart keepalived.service
}


kube::get_etcd_endpoint()
{
    local var=$2
    local temp=${var#*//}
    etcd_endpoint=${temp%%:*}
}

kube::save_master_ip()
{
    if [ ${KUBE_HA} == true ];then
        kube::get_etcd_endpoint $@
        set +e; ssh root@$etcd_endpoint "etcdctl mk ha_master ${LOCAL_IP}"; set -e
    fi
}

kube::copy_master_config()
{
    kube::get_etcd_endpoint $@
    local master_ip=$(ssh root@$etcd_endpoint "etcdctl get /ha_master")
    mkdir -p /etc/kubernetes
    scp -r root@${master_ip}:/etc/kubernetes/* /etc/kubernetes/
    systemctl daemon-reload && systemctl start kubelet
}

kube::set_label()
{
    export KUBECONFIG=/etc/kubernetes/admin.conf
    local hstnm=`hostname`
    local lowhstnm=$(echo $hstnm | tr '[A-Z]' '[a-z]')
    until kubectl get no | grep -i $lowhstnm; do sleep 1; done
    kubectl label node $lowhstnm kubeadm.alpha.kubernetes.io/role=master
}

kube::config_kubeadm()
{

  # kubeadm需要联网去找最新版本
  echo $HTTP_SERVER storage.googleapis.com >> /etc/hosts

  local endpoints=$2
  local temp=${endpoints#*=}
  local etcd0=$(echo $temp | awk -F ',' '{print $1}')
  local etcd1=$(echo $temp | awk -F ',' '{print $2}')
  local etcd2=$(echo $temp | awk -F ',' '{print $3}')
  local advertiseAddress=$1
  local advertiseAddress=${advertiseAddress#*=}

cat <<EOF >$HOME/kubeadm-config.yml
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
api:
  advertiseAddress: "$advertiseAddress"
#   bindPort: <int>
etcd:
  endpoints:
  - "$etcd0"
  - "$etcd1"
  - "$etcd2"
  # caFile: <path|string>
  # certFile: <path|string>
  # keyFile: <path|string>
kubernetesVersion: "v1.6.2"
networking:
  # dnsDomain: <string>
  # serviceSubnet: <cidr>
  # 这里一定要带上--pod-network-cidr参数，不然后面的flannel网络会出问题
  podSubnet: 12.240.0.0/12
EOF
}

kube::install_cni()
{
  # install flannel network
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl apply -f http://$HTTP_SERVER/network/kube-flannel-rbac.yml
  kubectl apply -f http://$HTTP_SERVER/network/kube-flannel.yml --namespace=kube-system
}

kube::master_up()
{
    shift

    kube::install_docker

    kube::load_images

    kube::install_k8s

    [ ${KUBE_HA} == true ] && kube::install_keepalived "MASTER" $@

    # 存储master ip， replica侧需要用这个信息来copy 配置
    kube::save_master_ip $@

    kube::config_kubeadm $@

    kubeadm init --config=$HOME/kubeadm-config.yml

    # 使能master，可以被调度到
    # kubectl taint nodes --all dedicated-

    echo -e "\033[32m 赶紧找地方记录上面的token！ \033[0m"

    kube::install_cni

    # 为了kubectl　get no的时候可以显示master标识
    kube::set_label

    # make kube-dns HA
    kubectl patch deployment kube-dns -p'{"spec":{"replicas":3}}' -n kube-system

    # show pods
    kubectl get po --all-namespaces
}

kube::replica_up()
{
    shift

    kube::install_docker

    kube::load_images

    kube::install_k8s

    kube::install_keepalived "BACKUP" $@

    kube::copy_master_config $@

    kube::set_label

}

kube::node_up()
{
    shift

    kube::install_docker

    kube::load_images

    kube::install_k8s

    kube::config_firewalld

    kubeadm join $@
}

kube::tear_down()
{
    systemctl stop kubelet.service
    docker ps -aq|xargs -I '{}' docker stop {}
    docker ps -aq|xargs -I '{}' docker rm {}
    df |grep /var/lib/kubelet|awk '{ print $6 }'|xargs -I '{}' umount {}
    rm -rf /var/lib/kubelet && rm -rf /etc/kubernetes/ && rm -rf /var/lib/etcd
    yum remove -y kubectl kubeadm kubelet kubernetes-cni
    if [ ${KUBE_HA} == true ]
    then
      yum remove -y keepalived
      rm -rf /etc/keepalived/keepalived.conf
    fi
    rm -rf /var/lib/cni
    rm -rf /etc/systemd/system/docker.service.d/*
    ip link del cni0
}

kube::test()
{
    shift
    kube::config_kubeadm $@
}

main()
{
    case $1 in
    "m" | "master" )
        kube::master_up $@
        ;;
    "r" | "replica" )
        kube::replica_up $@
        ;;
    "j" | "join" )
        kube::node_up $@
        ;;
    "d" | "down" )
        kube::tear_down
        ;;
    "t" | "test" )
        kube::test  $@
        ;;
    *)
        echo "usage: $0 m[master] | r[replica] | j[join] token | d[down] "
        echo "       $0 master to setup master "
        echo "       $0 replica to setup replica master "
        echo "       $0 join   to join master with token "
        echo "       $0 down   to tear all down ,inlude all data! so becarefull"
        echo "       unkown command $0 $@"
        ;;
    esac
}

main $@
