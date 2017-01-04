# 一键部署etcd集群

默认使用static方式部署集群，目前etcd集群没有采用tls加密

* 修改deploy-etcd.sh脚本里NODE_MAP变量为自己的etcd集群要部署的节点IP

* 和各节点建立免秘钥认证， 并自行确保各节点NTP时间同步

* 运行脚本批量进行部署

  脚本默认会部署temp-etcd目录的bin文件，删掉的话，脚本默认会去github地址下载tar包

  ```
  bash -c ./deploy-etcd.sh
  ```

note. 如果以前节点上部署过etcd， 自行清理遗留数据: ```systemctl stop etcd 和 rm -rf /var/lib/etcd/*```
