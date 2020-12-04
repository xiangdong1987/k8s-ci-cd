# k8s 环境安装
[TOC]
## 安装docker
* 宿主机网卡转发


```sh
#查看网卡转发状态
sysctl -a | grep -w net.ipv4.ip_forward

#转发状态不为1需要执行下面命令
cat <<EOF > /etc/sysctl.d/docker.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-ip4table = 1
net.ipv4.ip_forward = 1
EOF

#加载配置
sysctl -p /etc/sysctl.d/docker.conf
```
## 配置docker源

```sh
# 下载阿里源repo文件
curl -o /etc/yum.repos.d/Centos-7.repo http://mirrors.aliyun.com/repo/Centos-7.repo
curl -o /etc/yum.repos.d/docker-ce.repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo

# 清除历史
yum clean all && yum makecache

# 安装docker 
yum install -y docker-ce

# 查看可用版本
yum list docker-ce --showduplicates | sort -r

# 置顶版本安装
##yum install -y docker-ce-18.09.9

# 配置加速源
mkdir -p /etc/docker

vi /etc/docker/daemon.json
{
  "insecure-registries": [    
    "172.21.32.15:5000" 
  ],                          
  "registry-mirrors" : [
    "https://8xpk5wnt.mirror.aliyuncs.com"
  ]
}

# 启动docker 
systemctl enable docker && systemctl start docker

# 查看信息
docker info 

# 镜像导出和加载
docker save -o nginx-alpine.tar nginx-alpine
docker load -i nginx-alpine.tar

```
## docker本地镜像源
* 使用load加载本地镜像
```sh
#解压镜像
tar zxf registry.tar.gz -C /opt

#查看镜像
docker images

# 按照资源启动镜像
docker run --cpuset-cpus="0-3" --cpu-shares=512 --memory=500m nginx:alpine

#启动registry 镜像
docker run -d -p 5000:5000 --restart always -v /opt/registry-data/registry:/var/lib/registry --name registry registry:2

# 线上要使用证书
https://docs.docker.com/registry/deploying/#restricting-access

```
## docker数据持久化

```sh
## 挂载主机目录
$ docker run --name nginx -d  -v /opt:/opt -v /var/log:/var/log nginx:alpine
$ docker run --name mysql -e MYSQL_ROOT_PASSWORD=123456 -d -v /opt/mysql/:/var/lib/mysql mysql:5.7

## 使用volumes卷
$ docker volume ls
$ docker volume create my-vol
$ docker run --name nginx -d -v my-vol:/opt/my-vol nginx:alpine
$ docker exec -ti nginx touch /opt/my-vol/a.txt

## 验证数据共享
$ docker run --name nginx2 -d -v my-vol:/opt/hh nginx:alpine
$ docker exec -ti nginx2 ls /opt/hh/
a.txt

## 主机拷贝到容器
$ echo '123'>/tmp/test.txt
$ docker cp /tmp/test.txt nginx:/tmp
$ docker exec -ti nginx cat /tmp/test.txt
123

## 容器拷贝到主机
$ docker cp nginx:/tmp/test.txt ./


```

## docker 日志查看
```sh
## 查看全部日志
$ docker logs nginx

## 实时查看最新日志
$ docker logs -f nginx

## 从最新的100条开始查看
$ docker logs --tail=100 -f nginx
```

## 镜像容器明细

```sh
## 查看容器详细信息，包括容器IP地址等
$ docker inspect nginx

## 查看镜像的明细信息
$ docker inspect nginx:alpine
```
## docker 网络
```sh
# 查看网桥工具
yum install -y bridge-utils
# 查看
brctl show

## 清掉所有容器
$ docker rm -f `docker ps -aq`
$ docker ps
$ brctl show # 查看网桥中的接口，目前没有

## 创建测试容器test1
$ docker run -d --name test1 nginx:alpine
$ brctl show # 查看网桥中的接口，已经把test1的veth端接入到网桥中
$ ip a |grep veth # 已在宿主机中可以查看到
$ docker exec -ti test1 sh 
/ # ifconfig  # 查看容器的eth0网卡及分配的容器ip
/ # route -n  # 观察默认网关都指向了网桥的地址，即所有流量都转向网桥，等于是在veth pair接通了网线
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         172.17.0.1      0.0.0.0         UG    0      0        0 eth0
172.17.0.0      0.0.0.0         255.255.0.0     U     0      0        0 eth0

# 再来启动一个测试容器，测试容器间的通信
$ docker run -d --name test2 nginx:alpine
$ docker exec -ti test sh
/ # sed -i 's/dl-cdn.alpinelinux.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apk/repositories
/ # apk add curl
/ # curl 172.17.0.8:80

## 为啥可以通信，因为两个容器是接在同一个网桥中的，通信其实是通过mac地址和端口的的记录来做转发的。test1访问test2，通过test1的eth0发送ARP广播，网桥会维护一份mac映射表，我们可以大概通过命令来看一下，
$ brctl showmacs docker0
## 这些mac地址是主机端的veth网卡对应的mac，可以查看一下
$ ip a 
# 抓包
$ tcpdump -i eth0 port 8088 -w host.cap

```
# 安装k8s
## 准备阶段
* 修改主机名
```sh
# 在master节点
# #设置master节点的hostname
hostnamectl set-hostname k8s-master 

# 在slave-1节点
#设置slave1节点的hostname
hostnamectl set-hostname k8s-slave1 
# 命名生效
bash
```
* 修改host
```sh
cat >>/etc/hosts<<EOF
172.27.0.11 k8s-master
172.27.0.12 k8s-slave1
EOF
```
* 基础配置
```sh
#设置转发
iptables -P FORWARD ACCEPT

#关闭swap
swapoff -a

# 防止开机自动挂载 swap 分区
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 关闭selinux和防火墙
sed -ri 's#(SELINUX=).*#\1disabled#' /etc/selinux/config
setenforce 0
systemctl disable firewalld && systemctl stop firewalld

#修改内核参数
cat <<EOF >  /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward=1
vm.max_map_count=262144
EOF
modprobe br_netfilter
sysctl -p /etc/sysctl.d/k8s.conf

#设置yum源
curl -o /etc/yum.repos.d/Centos-7.repo http://mirrors.aliyun.com/repo/Centos-7.repo
curl -o /etc/yum.repos.d/docker-ce.repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=http://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=http://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg
        http://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF
yum clean all && yum makecache
```
* docker 安装
```sh
 ## 查看所有的可用版本
yum list docker-ce --showduplicates | sort -r
##安装旧版本 yum install docker-ce-cli-18.09.9-3.el7  docker-ce-18.09.9-3.el7
# yum install docker-ce-18.09.9
## 安装源里最新版本

yum install docker-ce

## 配置docker加速 自己镜像仓库
mkdir -p /etc/docker
vi /etc/docker/daemon.json
{
  "insecure-registries": [    
    "172.27.0.11:5000" 
  ],                          
  "registry-mirrors" : [
    "https://8xpk5wnt.mirror.aliyuncs.com"
  ]
}
## 启动docker
systemctl enable docker && systemctl start docker
```
## 部署kubernetes
* 安装 kubeadm, kubelet 和 kubectl(所有节点)
```sh
yum install -y kubelet-1.16.2 kubeadm-1.16.2 kubectl-1.16.2 --disableexcludes=kubernetes
## 查看kubeadm 版本
kubeadm version
## 设置kubelet开机启动
systemctl enable kubelet 
```
* 初始化配置文件(只在master节点上执行)
    * 需要非如下三个部分
```sh
$ kubeadm config print init-defaults > kubeadm.yaml
$ cat kubeadm.yaml
apiVersion: kubeadm.k8s.io/v1beta2
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: abcdef.0123456789abcdef
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 172.21.32.11  
  # apiserver地址，因为单master，所以配置master的节点内网IP
  bindPort: 6443
nodeRegistration:
  criSocket: /var/run/dockershim.sock
  name: k8s-master
  taints:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
---
apiServer:
  timeoutForControlPlane: 4m0s
apiVersion: kubeadm.k8s.io/v1beta2
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controllerManager: {}
dns:
  type: CoreDNS
etcd:
  local:
    dataDir: /var/lib/etcd
imageRepository: registry.aliyuncs.com/google_containers  
# 修改成阿里镜像源
kind: ClusterConfiguration
kubernetesVersion: v1.16.2
networking:
  dnsDomain: cluster.local
  podSubnet: 10.244.0.0/16  
  # Pod 网段，flannel插件需要使用这个网段
  serviceSubnet: 10.96.0.0/12
scheduler: {}
```
* 准备镜像
```sh
#查看镜像
kubeadm config images list --config kubeadm.yaml
#拉取镜像
kubeadm config images pull --config kubeadm.yaml
```
* 初始化节点
```sh
kubeadm init --config kubeadm.yaml
#cup 不够的情况下使用
kubeadm init --config kubeadm.yaml --ignore-preflight-errors=NumCPU
#失败情况下
kubeadm reset
```
> 问题kube最少要求2核机器
> failed to create kubelet: misconfiguration: kubelet cgroup driver: "cgroupfs" is different from docker cgroup driver: "systemd"
> 这个问题要修改docker 
> 1、修改docker的Cgroup Driver
> 修改/etc/docker/daemon.json文件
>{
>  "exec-opts": ["native.cgroupdriver=systemd"]
>}
> 重启docker
>systemctl daemon-reload
>systemctl restart docker
>主从都要清除 reset 要删除配置目录 
>rm -rf $HOME/.kube
>kubectl 配置有问题集群配置有问题
>kubectl config set-cluster e2e --server=https://1.2.3.4
* 安装网络插件
```sh
# flannel
wget https://raw.githubusercontent.com/coreos/flannel/2140ac876ef134e0ed5af15c65e414cf26827915/Documentation/kube-flannel.yml
# 修改flannel配置 指定网卡
$ vi kube-flannel.yml
...      
      containers:
      - name: kube-flannel
        image: quay.io/coreos/flannel:v0.11.0-amd64
        command:
        - /opt/bin/flanneld
        args:
        - --ip-masq
        - --kube-subnet-mgr
        - --iface=eth0  # 如果机器存在多网卡的话，指定内网网卡的名称，默认不指定的话会找第一块网
        resources:
          requests:
            cpu: "100m"
...

# 查看集群状态
kubectl get nodes

# 可以设置master不参与调度
kubectl taint node k8s-master node-role.kubernetes.io/master:NoSchedule-
```
* 验证集群
```sh
# 
kubectl run --generator=run-pod/v1 test-nginx --image=nginx:alpine
```
* 部署dashboard
```sh
# 推荐使用下面这种方式
$ wget https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta5/aio/deploy/recommended.yaml
$ vi recommended.yaml
# 修改Service为NodePort类型
......
kind: Service
apiVersion: v1
metadata:
  labels:
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard
  namespace: kubernetes-dashboard
spec:
  ports:
    - port: 443
      targetPort: 8443
  selector:
    k8s-app: kubernetes-dashboard
  type: NodePort  # 加上type=NodePort变成NodePort类型的服务
......
# 创建dashboard
kubectl create -f recommended.yaml
# 查看dashboard
kubectl -n kubernetes-dashboard get svc
# 访问查看
https://139.155.253.85:30133

# dashboard 创建token
$ vi admin.conf

kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: admin
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: admin
  namespace: kubernetes-dashboard

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin
  namespace: kubernetes-dashboard
  
# 创建用户
kubectl create -f admin.conf
# 获取secret 
kubectl -n kubernetes-dashboard get secret
# 获取token
kubectl -n kubernetes-dashboard describe secret xxxxx
```
* 清理环境
```sh
# 清除相关内容
$ kubeadm reset
$ ifconfig cni0 down && ip link delete cni0
$ ifconfig flannel.1 down && ip link delete flannel.1
$ rm -rf /var/lib/cni/
```
