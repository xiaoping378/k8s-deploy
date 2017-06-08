# 离线安装 kubernetes 高可用集群

经常遇到全新初始安装k8s集群的问题，所以想着搞成离线模式，本着最小依赖原则，采用纯shell脚本编写

基于Centos7.2-1511-minimal运行脚本测试OK， 默认安装docker1.12.6 etcd-v3.0.17 k8s-v1.6.2

本离线安装所有的依赖都打包放到了[百度网盘](https://pan.baidu.com/s/1nvQDdsl)，不放心安全的，可自行打包替换，就是些镜像tar包和rpms

简要说明

* 基于kubeadm搭建的kubernetes1.6 HA高可用集群
* 部署HA环境，需要先`存在etcd集群`，可使用etcd目录下的一键部署etcd集群脚本
* 共三台相互冗余，支持master和etcd分开部署
* master间通过keepalived做主-从-从冗余， controller和scheduler通过自带的--leader-elect选项
* 如果想部署kubeadm的默认模式，即全面容器化但都单实例的方式，可以参考[这里](https://github.com/xiaoping378/blog/issues/5)
* [TODO]现在的keepalived和etcd集群没用容器运行，后面有时间会尝试做到全面容器化
* 下图是官方ha模型，除了LB部分是用的keepalived的VIP功能, 此项目和官方基本一致
![overview](http://kubernetes.io/images/docs/ha.svg)

## 第一步
离线安装的基本思路是，在k8s-deploy目录下，临时启个http server， 节点上会从此拉取所依赖镜像和rpms

```
# python -m SimpleHTTPServer
Serving HTTP on 0.0.0.0 port 8000 ...
```

windows上可以用hfs临时启个http server， 自行google如何使用

## master侧

运行以下命令，初始化master， master侧如果是单核的话，会因资源不足， dns安装失败。

```
curl -L http://192.168.56.1:8000/k8s-deploy.sh | bash -s master \
    --VIP=192.168.56.103 \
    --etcd-endpoints=http://192.168.56.100:2379,http://192.168.56.101:2379,http://192.168.56.102:2379
```

* **192.168.56.1:8000** 是我的http-server, 注意要将k8s-deploy.sh 里的HTTP-SERVER变量也改下

* **--VIP** 是keepalived侧的浮动IP地址

* **--etcd-endpoints** 是你的etcd集群地址，如果第一次安装的话，可以使用etcd目录下的脚本一键安装

* 记录下你的token输出， minion侧需要用到

* 安装docker时，如果之前装过“不干净的”东西，可能会遇到依赖问题，我这里会遇到systemd-python依赖问题，
卸载之，即可
```yum remove -y systemd-python```

## replica master侧

在replica master侧运行下面的命令，会自动和第一个master组成冗余

最好和第一个master建立免秘钥认证，此过程需要从master那里拷贝配置
```
curl -L http://192.168.56.1:8000/k8s-deploy.sh | bash -s replica \
    --VIP=192.168.56.103 \
    --etcd-endpoints=http://192.168.56.100:2379,http://192.168.56.101:2379,http://192.168.56.102:2379
```

重复上面的步骤之后，会有一个3实例的HA集群，执行下面命令的时候可关闭第一个master，以验证高可用

* 验证vip漂移的网络影响

      sytemctl status keepalived
      # 确认vip落地情况
      # 模拟apiserver故障或者断电
      systemctl stop docker

* 验证kube-apiserver故障影响

  ```
  while true; do kubectl get po -n kube-system; sleep 1; done
  ```

## minion侧

视自己的情况而定， 使用第一个master侧生成的token， 注意这里的56.103是你的VIP地址

```
curl -L http://192.168.56.1:8000/k8s-deploy.sh |  bash -s join --token 32d98a.4076a0f48b5abd3f 192.168.56.103:6443
```

## 总结

* 脚本如果中间运行出错，就会自动退出，自己手动执行下退出前的地方，找原因，解决后，继续执行一开始的命令curl -L ... |　bash -s ...

* 1.5.1，默认关闭了匿名访问，可通过带token的方式访问API，参考[这里](http://kubernetes.io/docs/user-guide/accessing-the-cluster/),
  ```
  TOKEN=$(kubectl describe secret $(kubectl get secrets | grep default | cut -f1 -d ' ') | grep -E '^token' | cut -f2 -d':' | tr -d '\t')
  curl -k --tlsv1 -H "Authorization: Bearer $TOKEN" https://192.168.56.103:6443/api
  ```
  当然也可以通过更改apiserver的启动参数来开启匿名访问，自行google

* v1.6.2, kubeadm安装默认启用了RBAC权限认证体系，详细参考[这里](https://kubernetes.io/docs/admin/authorization/rbac/)

* 1.5 与 1.3给我感觉最大的变化是网络部分， 1.5启用了cni网络插件
  不需要像以前一样非要把flannel和docker绑在一起了（先启flannel才能启docker）。具体可以看[这里](https://kubernetes.io/docs/concepts/cluster-administration/network-plugins/#cni)

* 还有人反馈，有些node上kube-flannel会出现CrashLoopBackOff问题，
  ```
  我这里重现过一次，问题是dial tcp 10.96.0.1:443: i/o timeout， 也就是flannel联系不上api-server了。
  查看iptables正常，sep都存在, 清掉iptabels，重启kube-proxy可解决

  ```

* 为了kube-dns也处于高可用状态，可以部署3实例
  ```
  kubectl --namespace=kube-system scale deployment kube-dns --replicas=3
  ```

* 资源有限，想让master也参与调度pod的话，可以这样操作下
  ```
  kubectl taint node --all  node-role.kubernetes.io/master-
  ```
