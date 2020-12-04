[TOC]
## workload
* 单pod问题
    * 副本如何管理
    * 固定ip问题
* Workload (工作负载)
    - ReplicaSet: 代用户创建指定数量的pod副本数量，确保pod副本数量符合预期状态，并且支持滚动式自动扩容和缩容功能
    - Deployment：工作在ReplicaSet之上，用于管理无状态应用，目前来说最好的控制器。支持滚动更新和回滚功能，还提供声明式配置
    - DaemonSet：用于确保集群中的每一个节点只运行特定的pod副本，通常用于实现系统级后台任务。比如ELK服务
    - Job：只要完成就立即退出，不需要重启或重建
    - Cronjob：周期性任务控制，不需要持续后台运行
    - StatefulSet：管理有状态应用
* pod类型
    * 有状态pod
    * 无状态pod
## 创建mysql Deployment
* 创建mysql Deployment
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: demo
spec:
  replicas: 1	#指定Pod副本数 
  selector:		#指定Pod的选择器
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:	#给Pod打label
        app: mysql
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
## 创建myblog Deployment
* 业务deployment
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myblog
  namespace: demo
spec:
  replicas: 1	#指定Pod副本数
  selector:		#指定Pod的选择器
    matchLabels:
      app: myblog
  template:
    metadata:
      labels:	#给Pod打label
        app: myblog
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
## Deployment操作
```sh
# 获取
kubectl -n namespace get deploy
# 获取rs
kubectl -n namespace get rs
# 变更副本数量
kubectl -n demo scale deploy myblog --replicas=2
```
## pod驱逐策略
 K8S 有个特色功能叫 pod eviction，它在某些场景下如节点 NotReady，或者资源不足时，把 pod 驱逐至其它节点，这也是出于业务保护的角度去考虑的。

1. Kube-controller-manager: 周期性检查所有节点状态，当节点处于 NotReady 状态超过一段时间后，驱逐该节点上所有 pod。停掉kubelet
   - `pod-eviction-timeout`：NotReady 状态节点超过该时间后，执行驱逐，默认 5 min

2. Kubelet: 周期性检查本节点资源，当资源不足时，按照优先级驱逐部分 pod
   - `memory.available`：节点可用内存
   - `nodefs.available`：节点根盘可用存储空间
   - `nodefs.inodesFree`：节点inodes可用数量
   - `imagefs.available`：镜像存储盘的可用空间
   - `imagefs.inodesFree`：镜像存储盘的inodes可用数量
## 服务更新

修改dockerfile，重新打tag模拟服务更新。

更新方式：

- 修改yaml文件，使用`kubectl -n demo apply -f deploy-myblog.yaml`来应用更新
- `kubectl -n demo edit deploy myblog`在线更新
- `kubectl set image deploy myblog myblog=172.21.32.6:5000/myblog:v2 --record` 

修改文件测试：

```powershell
$ vi mybolg/blog/template/index.html

$ docker build . -t 172.21.32.6:5000/myblog:v2 -f Dockerfile_optimized
$ docker push 172.21.32.6:5000/myblog:v2
```

## 更新策略

```yaml
...
spec:
  replicas: 2	#指定Pod副本数
  selector:		#指定Pod的选择器
    matchLabels:
      app: myblog
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate		#指定更新方式为滚动更新，默认策略，通过get deploy yaml查看
    ...
```

策略控制：

- maxSurge：最大激增数, 指更新过程中, 最多可以比replicas预先设定值多出的pod数量, 可以为固定值或百分比,默认为desired Pods数的25%。计算时向上取整(比如3.4，取4)，更新过程中最多会有replicas + maxSurge个pod
- maxUnavailable： 指更新过程中, 最多有几个pod处于无法服务状态 , 可以为固定值或百分比，默认为desired Pods数的25%。计算时向下取整(比如3.6，取3)

>在Deployment rollout时，需要保证Available(Ready) Pods数不低于 desired pods number - maxUnavailable; 保证所有的非异常状态Pods数不多于 desired pods number + maxSurge*。

以myblog为例，使用默认的策略，更新过程:

1. maxSurge 25%，2个实例，向上取整，则maxSurge为1，意味着最多可以有2+1=3个Pod，那么此时会新创建1个ReplicaSet，RS-new，把副本数置为1，此时呢，副本控制器就去创建这个新的Pod
2. 同时，maxUnavailable是25%，副本数2*25%，向下取整，则为0，意味着，滚动更新的过程中，不能有少于2个可用的Pod，因此，旧的Replica（RS-old）会先保持不动，等RS-new管理的Pod状态Ready后，此时已经有3个Ready状态的Pod了，那么由于只要保证有2个可用的Pod即可，因此，RS-old的副本数会有2个变成1个，此时，会删掉一个旧的Pod
3. 删掉旧的Pod的时候，由于总的Pod数量又变成2个了，因此，距离最大的3个还有1个Pod可以创建，所以，RS-new把管理的副本数由1改成2，此时又会创建1个新的Pod，等RS-new管理了2个Pod都ready后，那么就可以把RS-old的副本数由1置为0了，这样就完成了滚动更新

```powershell
#查看滚动更新事件
$ kubectl -n demo describe deploy myblog
...
Events:
  Type    Reason             Age   From                   Message
  ----    ------             ----  ----                   -------
  Normal  ScalingReplicaSet  11s   deployment-controller  Scaled up replica set myblog-6cf56fc848 to 1
  Normal  ScalingReplicaSet  11s   deployment-controller  Scaled down replica set myblog-6fdcf98f9 to 1
  Normal  ScalingReplicaSet  11s   deployment-controller  Scaled up replica set myblog-6cf56fc848 to 2
  Normal  ScalingReplicaSet  6s    deployment-controller  Scaled down replica set myblog-6fdcf98f9 to 0
$ kubectl get rs
NAME                     DESIRED   CURRENT   READY   AGE
myblog-6cf56fc848   2         2         2       16h
myblog-6fdcf98f9    0         0         0       16h
```
## 服务回滚

通过滚动升级的策略可以平滑的升级Deployment，若升级出现问题，需要最快且最好的方式回退到上一次能够提供正常工作的版本。为此K8S提供了回滚机制。

**revision**：更新应用时，K8S都会记录当前的版本号，即为revision，当升级出现问题时，可通过回滚到某个特定的revision，默认配置下，K8S只会保留最近的几个revision，可以通过Deployment配置文件中的spec.revisionHistoryLimit属性增加revision数量，默认是10。

### 查看当前：

```powershell
$ kubectl -n demo rollout history deploy myblog ##CHANGE-CAUSE为空
$ kubectl delete -f deploy-myblog.yaml    ## 方便演示到具体效果，删掉已有deployment
```

### 记录回滚：

```powershell
$ kubectl create -f deploy-myblog.yaml --record

$ kubectl -n demo set image deploy myblog myblog=172.21.32.6:5000/myblog:v2 --record=true
```

### 查看deployment更新历史：

```powershell
$ kubectl -n demo rollout history deploy myblog
deployment.extensions/myblog
REVISION  CHANGE-CAUSE
1         kubectl create --filename=deploy-myblog.yaml --record=true
2         kubectl set image deploy myblog myblog=172.21.32.6:5000/demo/myblog:v1 --record=true
```

### 回滚到具体的REVISION:

```powershell
$ kubectl -n demo rollout undo deploy myblog --to-revision=1
deployment.extensions/myblog rolled back
```
## k8s调度

### NodeSelector

 `label`是`kubernetes`中一个非常重要的概念，用户可以非常灵活的利用 label 来管理集群中的资源，POD 的调度可以根据节点的 label 进行特定的部署。 

查看节点的label：

```powershell
$ kubectl get nodes --show-labels
```

为节点打label：

```powershell
$ kubectl label node k8s-master disktype=ssd
```

 当 node 被打上了相关标签后，在调度的时候就可以使用这些标签了，只需要在spec 字段中添加`nodeSelector`字段，里面是我们需要被调度的节点的 label。 

```yaml
...
spec:
  hostNetwork: true	# 声明pod的网络模式为host模式，效果通docker run --net=host
  volumes: 
  - name: mysql-data
    hostPath: 
      path: /opt/mysql/data
  nodeSelector:   # 使用节点选择器将Pod调度到指定label的节点
    component: mysql
  containers:
  - name: mysql
  	image: 172.21.32.6:5000/demo/mysql:5.7
...
```

### nodeAffinity

节点亲和性 ， 比上面的`nodeSelector`更加灵活，它可以进行一些简单的逻辑组合，不只是简单的相等匹配 。分为两种，软策略和硬策略。

 preferredDuringSchedulingIgnoredDuringExecution：软策略，如果你没有满足调度要求的节点的话，Pod就会忽略这条规则，继续完成调度过程，说白了就是满足条件最好了，没有满足就忽略掉的策略。

 requiredDuringSchedulingIgnoredDuringExecution ： 硬策略，如果没有满足条件的节点的话，就不断重试直到满足条件为止，简单说就是你必须满足我的要求，不然我就不会调度Pod。

```yaml
#要求 Pod 不能运行在128和132两个节点上，如果有个节点满足disktype=ssd的话就优先调度到这个节点上
...
spec:
      containers:
      - name: demo
        image: 172.21.32.6:5000/demo/myblog
        ports:
        - containerPort: 8002
      affinity:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                - matchExpressions:
                    - key: kubernetes.io/hostname
                      operator: NotIn
                      values:
                        - 192.168.136.128
                        - 192.168.136.132
            preferredDuringSchedulingIgnoredDuringExecution:
                - weight: 1
                  preference:
                    matchExpressions:
                    - key: disktype
                      operator: In
                      values:
                        - ssd
                        - sas
...
```

这里的匹配逻辑是 label 的值在某个列表中，现在`Kubernetes`提供的操作符有下面的几种：

- In：label 的值在某个列表中
- NotIn：label 的值不在某个列表中
- Gt：label 的值大于某个值
- Lt：label 的值小于某个值
- Exists：某个 label 存在
- DoesNotExist：某个 label 不存在

*如果nodeSelectorTerms下面有多个选项的话，满足任何一个条件就可以了；如果matchExpressions有多个选项的话，则必须同时满足这些条件才能正常调度 Pod*

### 污点（Taints）与容忍（tolerations）

对于`nodeAffinity`无论是硬策略还是软策略方式，都是调度 Pod 到预期节点上，而`Taints`恰好与之相反，如果一个节点标记为 Taints ，除非 Pod 也被标识为可以容忍污点节点，否则该 Taints 节点不会被调度Pod。

Taints(污点)是Node的一个属性，设置了Taints(污点)后，因为有了污点，所以Kubernetes是不会将Pod调度到这个Node上的。于是Kubernetes就给Pod设置了个属性Tolerations(容忍)，只要Pod能够容忍Node上的污点，那么Kubernetes就会忽略Node上的污点，就能够(不是必须)把Pod调度过去。

比如用户希望把 Master 节点保留给 Kubernetes 系统组件使用，或者把一组具有特殊资源预留给某些 Pod，则污点就很有用了，Pod 不会再被调度到 taint 标记过的节点。taint 标记节点举例如下：

设置污点：

```powershell
$ kubectl taint node [node_name] key=value:[effect]   
      其中[effect] 可取值： [ NoSchedule | PreferNoSchedule | NoExecute ]
       NoSchedule：一定不能被调度。
       PreferNoSchedule：尽量不要调度。
       NoExecute：不仅不会调度，还会驱逐Node上已有的Pod。
  示例：kubectl taint node k8s-master smoke=true:NoSchedule
```

去除污点：

```powershell
去除指定key及其effect：
     kubectl taint nodes [node_name] key:[effect]-    #这里的key不用指定value
                
 去除指定key所有的effect: 
     kubectl taint nodes node_name key-
 
 示例：
     kubectl taint node k8s-master smoke=true:NoSchedule
     kubectl taint node k8s-master smoke:NoExecute-
     kubectl taint node k8s-master smoke-
```

污点演示：

```powershell
## 给k8s-slave1打上污点，smoke=true:NoSchedule
$ kubectl taint node k8s-slave1 smoke=true:NoSchedule
$ kubectl taint node k8s-slave2 drunk=true:NoSchedule


## 扩容myblog的Pod，观察新Pod的调度情况
$ kuebctl -n demo scale deploy myblog --replicas=3
$ kubectl -n demo get po -w    ## pending
```



Pod容忍污点示例：`myblog/deployment/deploy-myblog-taint.yaml`

```powershell
...
spec:
      containers:
      - name: demo
        image: 172.21.32.6:5000/demo/myblog
      tolerations: #设置容忍性
      - key: "smoke" 
        operator: "Equal"  #如果操作符为Exists，那么value属性可省略,不指定operator，默认为Equal
        value: "true"
        effect: "NoSchedule"
      - key: "drunk" 
        operator: "Equal"  #如果操作符为Exists，那么value属性可省略,不指定operator，默认为Equal
        value: "true"
        effect: "NoSchedule"
	  #意思是这个Pod要容忍的有污点的Node的key是smoke Equal true,效果是NoSchedule，
      #tolerations属性下各值必须使用引号，容忍的值都是设置Node的taints时给的值。
```

```powershell
$ kubectl apply -f deploy-myblog-taint.yaml
```

```powershell
spec:
      containers:
      - name: demo
        image: 172.21.32.6:5000/demo/myblog
      tolerations:
        - operator: "Exists"
```

