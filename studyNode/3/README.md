[TOC]
## 优化
### 分拆pod
#### 中间件pod
* 将mysql中间件查分出来
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: mysql
  namespace: demo
  labels:
    component: mysql
spec:
  hostNetwork: true	# 声明pod的网络模式为host模式，效果通docker run --net=host
  volumes: 
  - name: mysql-data
    hostPath: 
      path: /opt/mysql/data
  nodeSelector:   # 使用节点选择器将Pod调度到指定label的节点
    component: mysql
  tolerations:
      - key: "node-role.kubernetes.io/master" 
        effect: "NoSchedule"  #只有两台机器master做存储    
  containers:
  - name: mysql
    image: 172.27.0.11:5000/mysql:5.7-utf8
    ports:
    - containerPort: 3306
    env:
    - name: MYSQL_ROOT_PASSWORD
      value: "123456"
    - name: MYSQL_DATABASE
      value: "myblog"
    resources:
      requests:
        memory: 100Mi
        cpu: 50m
      limits:
        memory: 500Mi
        cpu: 100m
    readinessProbe:
      tcpSocket:
        port: 3306
      initialDelaySeconds: 5
      periodSeconds: 10
    livenessProbe:
      tcpSocket:
        port: 3306
      initialDelaySeconds: 15
      periodSeconds: 20
    volumeMounts:
    - name: mysql-data
      mountPath: /var/lib/mysql
```
> mysql容器单独拆出一个pod实现中间独立
> 但是网络问题需要解决，方案是利用host模式和node主机公用网络

#### 业务pod
* 业务pod差分
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: myblog
  namespace: demo
  labels:
    component: myblog
spec:
  containers:
  - name: myblog
    image: 172.27.0.11:5000/myblog:v3
    imagePullPolicy: IfNotPresent
    env:
    - name: MYSQL_HOST   #  指定root用户的用户名
      value: "172.27.0.11"
    - name: MYSQL_PASSWD
      value: "123456"
    ports:
    - containerPort: 8002
    resources:
      requests:
        memory: 100Mi
        cpu: 50m
      limits:
        memory: 500Mi
        cpu: 100m
    livenessProbe:
      httpGet:
        path: /blog/index/
        port: 8002
        scheme: HTTP
      initialDelaySeconds: 10  # 容器启动后第一次执行探测是需要等待多少秒
      periodSeconds: 15 	# 执行探测的频率
      timeoutSeconds: 2		# 探测超时时间
    readinessProbe: 
      httpGet: 
        path: /blog/index/
        port: 8002
        scheme: HTTP
      initialDelaySeconds: 10 
      timeoutSeconds: 2
      periodSeconds: 15
```
### 安全风险
* configMap:通用配置 单独命名空间内单独使用隔离
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: myblog
  namespace: demo
data:
  MYSQL_HOST: "172.27.0.11"
  MYSQL_PORT: "3306"
```
* 使用配置
```yaml
spec:
  containers:
  - name: myblog
    image: 172.27.0.11:5000/myblog:v3
    imagePullPolicy: IfNotPresent
    env:
    - name: MYSQL_HOST
      valueFrom:
        configMapKeyRef:
          name: myblog
          key: MYSQL_HOST
    - name: MYSQL_PORT
      valueFrom:
        configMapKeyRef:
          name: myblog
          key: MYSQL_PORT
```
* 定义secret
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: myblog
  namespace: demo
type: Opaque
data:
  MYSQL_USER: cm9vdA==		#注意加-n参数， echo -n root|base64
  MYSQL_PASSWD: MTIzNDU2
```
* 使用secret

```yaml
spec:
  containers:
  - name: mysql
    image: 172.27.0.11:5000/mysql:5.7-utf8
    env:
    - name: MYSQL_USER
      valueFrom:
        secretKeyRef:
          name: myblog
          key: MYSQL_USER
    - name: MYSQL_PASSWD
      valueFrom:
        secretKeyRef:
          name: myblog
          key: MYSQL_PASSWD
    - name: MYSQL_DATABASE
      value: "myblog"
     
# 快捷方式
$ cat secret.txt
MYSQL_USER=root
MYSQL_PASSWD=123456
$ kubectl -n demo create secret generic myblog --from-env-file=secret.txt 
```
* 优化后结果
```yaml
spec:
  containers:
  - name: myblog
    image: 172.27.0.11:5000/myblog:v3
    imagePullPolicy: IfNotPresent
    env:
    - name: MYSQL_HOST
      valueFrom:
        configMapKeyRef:
          name: myblog
          key: MYSQL_HOST
    - name: MYSQL_PASSWD
      valueFrom:
        secretKeyRef:
          name: myblog
          key: MYSQL_PASSWD
    - name: MYSQL_USER
      valueFrom:
        secretKeyRef:
          name: myblog
          key: MYSQL_USER
    - name: MYSQL_PORT
      valueFrom:
        configMapKeyRef:
          name: myblog
          key: MYSQL_PORT

```

### 如何编写资源yaml
+ 拿来主义，从机器中已有的资源中拿
```sh
kubectl -n kube-system get po,deployment,ds
kubectl explain 
```
+ 学会在官网查找， https://kubernetes.io/docs/home/
+ 从kubernetes-api文档中查找， https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.16/#pod-v1-core

查看具体字段含义
### pod 生命周期
Pod的状态如下表所示：

| 状态值            | 描述                                                         |
| ----------------- | ------------------------------------------------------------ |
| Pending           | API Server已经创建该Pod，等待调度器调度                      |
| ContainerCreating | 镜像正在创建                                                 |
| Running           | Pod内容器均已创建，且至少有一个容器处于运行状态、正在启动状态或正在重启状态 |
| Succeeded         | Pod内所有容器均已成功执行退出，且不再重启                    |
| Failed            | Pod内所有容器均已退出，但至少有一个容器退出为失败状态        |
| CrashLoopBackOff  | Pod内有容器启动失败，比如配置文件丢失导致主进程启动失败      |
| Unknown           | 由于某种原因无法获取该Pod的状态，可能由于网络通信不畅导致    |

* 测试
```yaml
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-start-stop
  namespace: demo
  labels:
    component: demo-start-stop
spec:
  initContainers: #初始化容器
  - name: init
    image: busybox
    command: ['sh', '-c', 'echo $(date +%s): INIT >> /loap/timing']
    volumeMounts:
    - mountPath: /loap
      name: timing
  containers:
  - name: main #容器启动
    image: busybox
    command: ['sh', '-c', 'echo $(date +%s): START >> /loap/timing;
sleep 10; echo $(date +%s): END >> /loap/timing;']
    volumeMounts:
    - mountPath: /loap 
      name: timing
    livenessProbe:#生命检查
      exec:
        command: ['sh', '-c', 'echo $(date +%s): LIVENESS >> /loap/timing']
    readinessProbe:#可读
      exec:
        command: ['sh', '-c', 'echo $(date +%s): READINESS >> /loap/timing']
    lifecycle:
      postStart:#开始之前
        exec:
          command: ['sh', '-c', 'echo $(date +%s): POST-START >> /loap/timing']
      preStop:#被kill 出发
        exec:
          command: ['sh', '-c', 'echo $(date +%s): PRE-STOP >> /loap/timing']
  volumes:
  - name: timing
    hostPath:
      path: /tmp/loap
```