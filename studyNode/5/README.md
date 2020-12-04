[TOC]
## Service 作用
* service是一组pod的服务抽象，相当于一组pod的LB，负责将请求分发给对应的pod。service会为这个LB提供一个IP，一般称为cluster IP 。使用Service对象，通过selector进行标签选择，找到对应的Pod
## 创建myblog Service
```yaml
apiVersion: v1
kind: Service
metadata:
  name: myblog
  namespace: demo
spec:
  ports:
  - port: 80
    protocol: TCP
    targetPort: 8002
  selector:
    app: myblog
  type: ClusterIP
```
* 实现
    * Service与Pod如何关联:service对象创建的同时，会创建同名的endpoints对象，若服务设置了readinessProbe, 当readinessProbe检测失败时，endpoints列表中会剔除掉对应的pod_ip，这样流量就不会分发到健康检测失败的Pod中

## Service 访问
* 为mysql服务创建service：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: demo
spec:
  ports:
  - port: 3306
    protocol: TCP
    targetPort: 3306
  selector:
    app: mysql
  type: ClusterIP
```
* 目前使用hostNetwork部署，通过宿主机ip+port访问，弊端：
    - 服务使用hostNetwork，使得宿主机的端口大量暴漏，存在安全隐患
    - 容易引发端口冲突

- 服务均属于k8s集群，尽可能使用k8s的网络访问，因此可以对目前myblog访问mysql的方式做改造：

    - 为mysql创建一个固定clusterIp的Service，把clusterIp配置在myblog的环境变量中
    - 利用集群服务发现的能力，组件之间通过service name来访问

## 服务发现
在k8s集群中，组件之间可以通过定义的Service名称实现通信。

演示服务发现：

```powershell
## 演示思路：在myblog的容器中直接通过service名称访问服务，观察是否可以访问通

# 先查看服务
$ kd get svc
NAME     TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
myblog   ClusterIP   10.99.174.93    <none>        80/TCP     59m
mysql    ClusterIP   10.108.214.84   <none>        3306/TCP   35m

# 进入myblog容器
$ kd exec -ti myblog-5c97d79cdb-j485f bash
[root@myblog-5c97d79cdb-j485f myblog]# curl mysql:3306
5.7.29 )→  (mysql_native_password ot packets out of order
[root@myblog-5c97d79cdb-j485f myblog]# curl myblog/blog/index/
我的博客列表

```

虽然podip和clusterip都不固定，但是service name是固定的，而且具有完全的跨集群可移植性，因此组件之间调用的同时，完全可以通过service name去通信，这样避免了大量的ip维护成本，使得服务的yaml模板更加简单。因此可以对mysql和myblog的部署进行优化改造：

1. mysql可以去掉hostNetwork部署，使得服务只暴漏在k8s集群内部网络
2. configMap中数据库地址可以换成Service名称，这样跨环境的时候，配置内容基本上可以保持不用变化

修改deploy-mysql.yaml

```yaml
    spec:
      hostNetwork: true	# 去掉此行
      volumes: 
      - name: mysql-data
        hostPath: 
          path: /opt/mysql/data

```

修改configmap.yaml

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: myblog
  namespace: demo
data:
  MYSQL_HOST: "mysql"	# 此处替换为mysql
  MYSQL_PORT: "3306"
```

应用修改：

```powershell
$ kubectl apply -f configmap.yaml
$ kubectl apply -f deploy-mysql.yaml

## 重建pod
$ kubectl -n demo delete po mysql-7f747644b8-6npzn

#去掉taint
$ kubectl taint node k8s-slave1 smoke-
$ kubectl taint node k8s-slave2 drunk-

## myblog不用动，会自动因健康检测不过而重启
```

服务发现实现：

 `CoreDNS`是一个`Go`语言实现的链式插件`DNS服务端`，是CNCF成员，是一个高性能、易扩展的`DNS服务端`。 

```powershell
$ kubectl -n kube-system get po -o wide|grep dns
coredns-d4475785-2w4hk             1/1     Running   0          4d22h   10.244.0.64       
coredns-d4475785-s49hq             1/1     Running   0          4d22h   10.244.0.65

# 查看myblog的pod解析配置
$ kubectl -n demo exec -ti myblog-5c97d79cdb-j485f bash
[root@myblog-5c97d79cdb-j485f myblog]# cat /etc/resolv.conf
nameserver 10.96.0.10
search demo.svc.cluster.local svc.cluster.local cluster.local
options ndots:5

## 10.96.0.10 从哪来
$ kubectl -n kube-system get svc
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)         AGE
kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP   51d

## 启动pod的时候，会把kube-dns服务的cluster-ip地址注入到pod的resolve解析配置中，同时添加对应的namespace的search域。 因此跨namespace通过service name访问的话，需要添加对应的namespace名称，
service_name.namespace_name
$ kubectl get svc
NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
kubernetes   ClusterIP   10.96.0.1    <none>        443/TCP   26h
```

## NodePort
cluster-ip为虚拟地址，只能在k8s集群内部进行访问，集群外部如果访问内部服务，实现方式之一为使用NodePort方式。NodePort会默认在 30000-32767 ，不指定的会随机使用其中一个。

`myblog/deployment/svc-myblog-nodeport.yaml`

```powershell
apiVersion: v1
kind: Service
metadata:
  name: myblog-np
  namespace: demo
spec:
  ports:
  - port: 80
    protocol: TCP
    targetPort: 8002
  selector:
    app: myblog
  type: NodePort
```

查看并访问服务：

```powershell
$ kd create -f svc-myblog-nodeport.yaml
service/myblog-np created
$ kd get svc
NAME        TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)        AGE
myblog      ClusterIP   10.99.174.93     <none>        80/TCP         102m
myblog-np   NodePort    10.105.228.101   <none>        80:30647/TCP   4s
mysql       ClusterIP   10.108.214.84    <none>        3306/TCP       77m

#集群内每个节点的NodePort端口都会进行监听
$ curl 192.168.136.128:30647/blog/index/
我的博客列表
$ curl 192.168.136.131:30647/blog/index/
我的博客列表
## 浏览器访问
```
## kube-proxy

 运行在每个节点上，监听 API Server 中服务对象的变化，再通过创建流量路由规则来实现网络的转发。[参照]( https://kubernetes.io/docs/concepts/services-networking/service/#virtual-ips-and-service-proxies )

有三种模式：

- User space, 让 Kube-Proxy 在用户空间监听一个端口，所有的 Service 都转发到这个端口，然后 Kube-Proxy 在内部应用层对其进行转发 ， 所有报文都走一遍用户态，性能不高，k8s v1.2版本后废弃。
- Iptables， 当前默认模式，完全由 IPtables 来实现， 通过各个node节点上的iptables规则来实现service的负载均衡，但是随着service数量的增大，iptables模式由于线性查找匹配、全量更新等特点，其性能会显著下降。 
- IPVS， 与iptables同样基于Netfilter，但是采用的hash表，因此当service数量达到一定规模时，hash查表的速度优势就会显现出来，从而提高service的服务性能。 k8s 1.8版本开始引入，1.11版本开始稳定，需要开启宿主机的ipvs模块。

```powershell
$ iptables-save |grep -v myblog-np|grep  "demo/myblog"
-A KUBE-SERVICES ! -s 10.244.0.0/16 -d 10.99.174.93/32 -p tcp -m comment --comment "demo/myblog: cluster IP" -m tcp --dport 80 -j KUBE-MARK-MASQ
-A KUBE-SERVICES -d 10.99.174.93/32 -p tcp -m comment --comment "demo/myblog: cluster IP" -m tcp --dport 80 -j KUBE-SVC-WQNGJ7YFZKCTKPZK

$ iptables-save |grep KUBE-SVC-WQNGJ7YFZKCTKPZK
-A KUBE-SVC-WQNGJ7YFZKCTKPZK -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-GB5GNOM5CZH7ICXZ
-A KUBE-SVC-WQNGJ7YFZKCTKPZK -j KUBE-SEP-7GWC3FN2JI5KLE47

$  iptables-save |grep KUBE-SEP-GB5GNOM5CZH7ICXZ
-A KUBE-SEP-GB5GNOM5CZH7ICXZ -p tcp -m tcp -j DNAT --to-destination 10.244.1.158:8002

$ iptables-save |grep KUBE-SEP-7GWC3FN2JI5KLE47
-A KUBE-SEP-7GWC3FN2JI5KLE47 -p tcp -m tcp -j DNAT --to-destination 10.244.1.159:8002
```
## Kubernetes服务访问之Ingress

对于Kubernetes的Service，无论是Cluster-Ip和NodePort均是四层的负载，集群内的服务如何实现七层的负载均衡，这就需要借助于Ingress，Ingress控制器的实现方式有很多，比如nginx, Contour, Haproxy, trafik, Istio，我们以nginx的实现为例做演示。

Ingress-nginx是7层的负载均衡器 ，负责统一管理外部对k8s cluster中service的请求。主要包含：

- ingress-nginx-controller：根据用户编写的ingress规则（创建的ingress的yaml文件），动态的去更改nginx服务的配置文件，并且reload重载使其生效（是自动化的，通过lua脚本来实现）；
- ingress资源对象：将Nginx的配置抽象成一个Ingress对象，每添加一个新的Service资源对象只需写一个新的Ingress规则的yaml文件即可（或修改已存在的ingress规则的yaml文件）

### 示意图：

![3247b495e92a4fff95ed290785a4450b.png](evernotecid://43BABE84-B7F2-4A18-86D3-8B26DB0999D2/appyinxiangcom/9859816/ENResource/p62)

### 实现逻辑

1）ingress controller通过和kubernetes api交互，动态的去感知集群中ingress规则变化
2）然后读取ingress规则(规则就是写明了哪个域名对应哪个service)，按照自定义的规则，生成一段nginx配置
3）再写到nginx-ingress-controller的pod里，这个Ingress controller的pod里运行着一个Nginx服务，控制器把生成的nginx配置写入/etc/nginx.conf文件中
4）然后reload一下使配置生效。以此达到域名分别配置和动态更新的问题。

### 安装

  [官方文档](https://github.com/kubernetes/ingress-nginx/blob/master/docs/deploy/index.md)

```powershell
$ wget https://raw.githubusercontent.com/kubernetes/ingress-nginx/nginx-0.30.0/deploy/static/mandatory.yaml
## 或者使用myblog/deployment/ingress/mandatory.yaml
## 修改部署节点
$ grep -n5 nodeSelector mandatory.yaml
212-    spec:
213-      hostNetwork: true #添加为host模式
214-      # wait up to five minutes for the drain of connections
215-      terminationGracePeriodSeconds: 300
216-      serviceAccountName: nginx-ingress-serviceaccount
217:      nodeSelector:
218-        ingress: "true"		#替换此处，来决定将ingress部署在哪些机器
219-      containers:
220-        - name: nginx-ingress-controller
221-          image: quay.io/kubernetes-ingress-controller/nginx-ingress-controller:0.30.0
222-          args:
```
> 如果国外镜像无法使用可以使用如下镜像
> quay.azk8s.cn/kubernetes-ingress-controller/nginx-ingress-controller:0.30.0


使用示例：`myblog/deployment/ingress.yaml`

```yaml
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: myblog
  namespace: demo
spec:
  rules:
  - host: myblog.devops.cn
    http:
      paths:
      - path: /
        backend:
          serviceName: myblog
          servicePort: 80
```

ingress-nginx动态生成upstream配置：

```yaml
...
                server_name myblog.devops.cn ;

                listen 80  ;
                listen [::]:80  ;
                listen 443  ssl http2 ;
                listen [::]:443  ssl http2 ;

                set $proxy_upstream_name "-";

                ssl_certificate_by_lua_block {
                        certificate.call()
                }

                location / {

                        set $namespace      "demo";
                        set $ingress_name   "myblog";
 ...
```
### 访问

域名解析服务，将 `myblog.devops.cn`解析到ingress的地址上。ingress是支持多副本的，高可用的情况下，生产的配置是使用lb服务（内网F5设备，公网elb、slb、clb，解析到各ingress的机器，如何域名指向lb地址）

本机，添加如下hosts记录来演示效果。

```json
192.168.136.128 myblog.devops.cn
```

然后，访问 http://myblog.devops.cn/blog/index/

HTTPS访问：

```powershell
#自签名证书
$ openssl req -x509 -nodes -days 2920 -newkey rsa:2048 -keyout tls.key -out tls.crt -subj "/CN=*.devops.cn/O=ingress-nginx"

