#!/bin/bash
set -x
set -e

HTTP_SERVER=10.2.11.177:8000
KUBE_HA=true

KUBE_REPO_PREFIX=gcr.io/google_containers
KUBE_ETCD_IMAGE=quay.io/coreos/etcd:v3.0.15

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

    mkdir -p /etc/systemd/system/docker.service.d
cat <<EOF >/etc/systemd/system/docker.service.d/10-docker.conf
[Service]
    ExecStart=
    ExecStart=/usr/bin/dockerd -s overlay --selinux-enabled=false
EOF

    systemctl daemon-reload && systemctl restart docker.service
}

kube::load_images()
{
    mkdir -p /tmp/k8s

    images=(
        kube-apiserver-amd64_v1.5.1
        kube-controller-manager-amd64_v1.5.1
        kube-scheduler-amd64_v1.5.1
        kube-proxy-amd64_v1.5.1
        pause-amd64_3.0
        kube-discovery-amd64_1.0
        kubedns-amd64_1.9
        exechealthz-amd64_1.2
        kube-dnsmasq-amd64_1.4
        dnsmasq-metrics-amd64_1.0
        etcd_v3.0.15
        flannel-amd64_v0.7.0
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

kube::install_bin()
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

kube::wait_apiserver()
{
    until curl http://127.0.0.1:8080; do sleep 1; done
}

kube::disable_static_pod()
{
    # remove the waring log in kubelet
    sed -i 's/--pod-manifest-path=\/etc\/kubernetes\/manifests//g' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    systemctl daemon-reload && systemctl restart kubelet.service
}

kube::get_env()
{
  HA_STATE=$1
  [ $HA_STATE == "MASTER" ] && HA_PRIORITY=200 || HA_PRIORITY=`expr 200 - ${RANDOM} / 1000 + 1`
  KUBE_VIP=$(echo $2 |awk -F= '{print $2}')
  VIP_PREFIX=$(echo ${KUBE_VIP} | cut -d . -f 1,2,3)
  #dhcp和static地址的不同取法
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
    script "curl http://127.0.0.1:8080"
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


kube::get_etcd_master()
{
    local var=$2
    local temp=${var#*//}
    etcd_master=${temp%%:*}
}

kube::save_master_ip()
{
    set +e
    # 应该从 $2 里拿到 etcd群的 --endpoints, 这里默认走的127.0.0.1:2379
    if [ ${KUBE_HA} == true ];then
        ssh root@$etcd_master "etcdctl mk ha_master ${etcd_master}"
    fi
    set -e
}

kube::copy_master_config()
{
    local master_ip=$(ssh root@$etcd_master "etcdctl get /ha_master")
    mkdir -p /etc/kubernetes
    scp -r root@${master_ip}:/etc/kubernetes/* /etc/kubernetes/
    systemctl start kubelet
}

kube::set_label()
{
  #until kubectl get no | grep -i `hostname`; do sleep 1; done
  #kubectl label node `hostname` kubeadm.alpha.kubernetes.io/role=master
    local hstnm=`hostname`
    local lowhstnm=$(echo $hstnm | tr '[A-Z]' '[a-z]') 
    until kubectl get no | grep -i $lowhstnm; do sleep 1; done
    kubectl label node $lowhstnm kubeadm.alpha.kubernetes.io/role=master
}

kube::master_up()
{
    shift

    kube::install_docker

    kube::load_images

    kube::install_bin

    [ ${KUBE_HA} == true ] && kube::install_keepalived "MASTER" $@

    # 存储master ip， replica侧需要用这个信息来copy 配置
    kube::save_master_ip

    # 这里一定要带上--pod-network-cidr参数，不然后面的flannel网络会出问题
    kubeadm init --use-kubernetes-version=v1.5.1  --pod-network-cidr=10.244.0.0/16 $@

    # 使能master，可以被调度到
    # kubectl taint nodes --all dedicated-

    echo -e "\033[32m 赶紧找地方记录上面的token！ \033[0m"

    # install flannel network
    kubectl apply -f http://$HTTP_SERVER/network/kube-flannel.yaml --namespace=kube-system

    # show pods
    kubectl get po --all-namespaces
}

kube::replica_up()
{
    shift

    kube::install_docker

    kube::load_images

    kube::install_bin

    kube::get_etcd_master $@

    kube::install_keepalived "BACKUP" $@

    kube::copy_master_config

    kube::set_label

}

kube::node_up()
{
    kube::install_docker

    kube::load_images

    kube::install_bin

    kube::disable_static_pod

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
    ip link del cni0
}

kube::shl_test()
{
    kube::get_etcd_master $@
    kube::copy_master_config
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
        shift
        kube::node_up $@
        ;;
    "d" | "down" )
        kube::tear_down $@
        ;;
    "t" | "test" )
        kube::shl_test  $@
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
