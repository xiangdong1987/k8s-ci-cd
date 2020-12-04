[TOC]
## Jenkins 部署
### 部署分析
1. 第一次启动很慢，先创建
2. 因为后面jenkins与kubernetes集群进行集成，会需要调用kubernetes集群api,因此安装的时候穿件sa并赋予cluster-admin的权限
3. 默认部署到jenkins=true的节点
4. 初始化容器来设置权限
5. ingress 外部访问
6. 数据存储通过hostpath挂载到宿主机中

`jenkins/jenkis-all.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: jenkins
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
  namespace: jenkins
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: jenkins-crb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: jenkins
  namespace: jenkins
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: jenkins-master
  namespace: jenkins
spec:
  replicas: 1
  serviceName: jenkins
  selector:
    matchLabels:
      devops: jenkins-master
  template:
    metadata:
      labels:
        devops: jenkins-master
    spec:
      nodeSelector:
        jenkins: "true"
      tolerations:
      - operator: "Exists"
      serviceAccount: jenkins #Pod 需要使用的服务账号
      initContainers:
      - name: fix-permissions
        image: busybox
        command: ["sh", "-c", "chown -R 1000:1000 /var/jenkins_home"]
        securityContext:
          privileged: true
        volumeMounts:
        - name: jenkinshome
          mountPath: /var/jenkins_home
      containers:
      - name: jenkins
        image: 172.27.0.11:5000/jenkinsci/blueocean
        securityContext: #root用户运行
          runAsUser: 0
        imagePullPolicy: IfNotPresent
        ports:
        - name: http #Jenkins Master Web 服务端口
          containerPort: 8080
        - name: slavelistener #Jenkins Master 供未来 Slave 连接的端口
          containerPort: 50000
        volumeMounts:
        - name: jenkinshome
          mountPath: /var/jenkins_home
        - name: docker #挂载本机的docker配置
          mountPath: /var/run/docker.sock
        - name: docker-cli
          mountPath: /usr/bin/docker 
        - name: docker-conf
          mountPath: /etc/docker
        - name: kb-cli
          mountPath: /usr/bin/kubectl
        - name: kb-conf
          mountPath: ~/.kebu/
        env:
        - name: JAVA_OPTS
          value: "-Xms4096m -Xmx5120m -Duser.timezone=Asia/Shanghai -Dhudson.model.DirectoryBrowserSupport.CSP="
      volumes:
      - name: jenkinshome
        hostPath:
          path: /var/jenkins_home/
      - name: docker
        hostPath:
          path: /var/run/docker.sock
      - name: docker-cli
        hostPath:
          path: /usr/bin/docker   
      - name: docker-conf
        hostPath:
          path: /etc/docker           
      - name: kb-cli
        hostPath:
          path: /usr/bin/kubectl 
      - name: kb-conf
        hostPath:
          path: ~/.kebu/
          
---
apiVersion: v1
kind: Service
metadata:
  name: jenkins
  namespace: jenkins
spec:
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  - name: slavelistener
    port: 50000
    targetPort: 50000
  selector:
    devops: jenkins-master
---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: jenkins-web
  namespace: jenkins
spec:
  rules:
  - host: jenkins.qq.com
    http:
      paths:
      - backend:
          serviceName: jenkins
          servicePort: 8080
      path: /    
```
* 使用jenkins启动日志中的密码，或者执行下面的命令获取解锁管理员密码
```sh
kubectl -n jenkins exec -it jenkins-master-1 bash
cat /var/jenkins_home/secrets/initialAdminPassword
```
* 优化插件下载速度
```sh
cd /var/jenkins_home/updates
sed -i 's/http:\/\/update.jenkins-ci.org\/download/https:\/\/mirrors.tuna.tsinghua.edu.cn\/jenkins/g' default.json
sed -i 's/http:\/\/www.google.com/https:\/\/www.baidu.com/g' default.json
```
* 重启pod 
```sh
kj scale sts jenkins-master --replicas=0
kj scale sts jenkins-master --replicas=1
```
* 下载中文插件
## jenkins集成gitlab
### 演示目标
* 代码提交gitlab，自动触发jenkins任务
* jenkins 任务完成后发送钉钉系统通知

### 演示准备
* gitlab 代码仓库搭建
```sh
docker run -d --hostname 139.155.240.61 -p 8443:443 -p 8880:80 -p 8022:22 -m 5GB --name gitlab --restart always -v /opt/gitlab/config:/etc/gitlab -v /opt/gitlab/logs:/var/log/gitlab -v /opt/gitlab/data:/var/opt/gitlab 172.27.0.11:5000/gitlab/gitlab-ce:v1
```
* 设置root密码
访问 http://139.155.253.85 设置管理员密码
> 系统必须4G 以上内存才能运行起来

### 钉钉机器人
https://oapi.dingtalk.com/robot/send?access_token=ec00a17576b0e07a9ade0f00a26b338f5ae64b3e5b1279a6902934271a7d6b49
```sh
curl 'https://oapi.dingtalk.com/robot/send?access_token=ec00a17576b0e07a9ade0f00a26b338f5ae64b3e5b1279a6902934271a7d6b49' \
-H 'Content-Type: application/json' \
-d '{"msgtype":"text",
    "text":{
        "content":"xdd我就是我，是不一样的烟火"
        }
     }'   
```
### jenkins结合gitlab
1. jenkins下载gitlab 插件
2. jenkins 配置gitlab 使用apitoken模式
3. jenkins创建工程 自由风格配置gitlab
4. gitlab webhook 配置
5. jenkins触发器构建 配置到gitlab secrettoken
6. 构建脚本配置
* jenkins 流程
    * jenkins 收到事件拉取代码
    * 执行构建（包含容器构建，代码检查，消息通知等等）

### 定制化jenkins 容器
* 定制自己的jenkins镜像
`Dockerfile`
```yaml
FROM jenkinsci/blueocean
LABLE maintainer="xiangdong198719@gmail.com"

## 用最近的插件列表文件替换插件文件
COPY plugins.txt /usr/share/jenkins/ref/

## 执行插件安装
RUN /usr/local/bin/install-plugins.sh < /usr/share/jenkins/ref/plugins.txt
```
* 获取 plugins 脚本
```sh
curl -sSL "http://admin:123456@10.100.192.111:8080/pluginManager/api/xml?depth=1&xpath=/*/*/shortName|/*/*/version&wrapper=plugins" | perl -pe 's/.*?<shortName>([\w-]+).*?<version>([^<]+)()(<\/\w+>)+/\1:\2\n/g'|sed 's/ /:/' > plugin.txt
```
## Jenkins流水线pipeline
### Jenkisfile
* 使用jenkinsfile管理pipeline
* 在项目中新建jinkensfile文件，拷贝以后的script内容
* 配置pipeline任务，流水线定义为pipeline script from scm
* 执行push 代码测试
`jenkins/pipeline/p2.yaml`
```yaml
pipeline {
   agent { label 'master'}

   stages {
      stage('printenv') {
         steps {
            echo 'Hello World'
            sh 'printenv'
         }
      }
      stage('check') {
         steps {
            checkout([$class: 'GitSCM', branches: [[name: '*/master']], doGenerateSubmoduleConfigurations: false, extensions: [], submoduleCfg: [], userRemoteConfigs: [[credentialsId: 'gitlab-user', url: 'http://139.155.240.61:8880/root/myblog.git']]])
         }
      }
      stage('build-image') {
         steps {
            retry(2) { sh 'docker build . -t myblog:latest'}
         }
      }
   }
}

```
### 优化Jenkinsfile
* 简化检出利用checkout scm 简化
* 使用环境变量替代镜像名称
* 集成钉钉消息推送
`jenkins/pipeline/p2.yaml`
```YAML
pipeline {
    agent { label 'master'}

    stages {
        stage('printenv') {
            steps {
            echo 'Hello World'
            sh 'printenv'
            }
        }
        stage('check') {
            steps {
                checkout scm 
            }
        }
        stage('build-image') {
            steps {
            	retry(2) { sh 'docker build . -t myblog:${GIT_COMMIT}'} 
            }
        }
    }
    post {
        success {
            echo 'Congratulations!'
            sh """
                curl 'https://oapi.dingtalk.com/robot/send?access_token=ec00a17576b0e07a9ade0f00a26b338f5ae64b3e5b1279a6902934271a7d6b49' \
                    -H 'Content-Type: application/json' \
                    -d '{"msgtype": "text",
                            "text": {
                                "content": "😄👍构建成功👍😄\n 关键字：xdd\n 项目名称: ${JOB_BASE_NAME}\n Commit Id: ${GIT_COMMIT}\n 构建地址：${RUN_DISPLAY_URL}"
                        }
                }'
            """
        }
        failure {
            echo 'Oh no!'
            sh """
                curl 'https://oapi.dingtalk.com/robot/send?access_token=ec00a17576b0e07a9ade0f00a26b338f5ae64b3e5b1279a6902934271a7d6b49' \
                    -H 'Content-Type: application/json' \
                    -d '{"msgtype": "text",
                            "text": {
                                "content": "😖❌构建失败❌😖\n 关键字：xdd\n 项目名称: ${JOB_BASE_NAME}\n Commit Id: ${GIT_COMMIT}\n 构建地址：${RUN_DISPLAY_URL}"
                        }
                }'
            """
        }
        always {
            echo 'I will always say Hello again!'
        }
    }
}
```
### jenkins 实现部署项目到k8s
* 准备部署文件
* 在代码目录添加deploy目录
* 优化部署文件

`service.yaml`
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
`ingreess.yaml`
```yaml
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: myblog
  namespace: demo
spec:
  rules:
  - host: myblog.qq.com
    http:
      paths:
      - path: /
        backend:
          serviceName: myblog
          servicePort: 80
```
`deploy.yaml`
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
        image: {{IMAGE_URL}} #指定动态版本
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
* 部署文件
    * 添加环境变量
    * 镜像推送和部署
    
`p4.yaml`
```yaml
pipeline {
    agent { label 'master'}

    environment {
        IMAGE_REPO = "172.27.0.11:5000/myblog"
    }

    stages {
        stage('printenv') {
            steps {
            echo 'Hello World'
            sh 'printenv'
            }
        }
        stage('check') {
            steps {
                checkout scm
            }
        }
        stage('build-image') {
            steps {
                retry(2) { sh 'docker build . -t ${IMAGE_REPO}:${GIT_COMMIT}'}
            }
        }
        stage('push-image') {
            steps {
                retry(2) { sh 'docker push ${IMAGE_REPO}:${GIT_COMMIT}'}
            }
        }
        stage('deploy') {
            steps {
                sh "sed -i 's#{{IMAGE_URL}}#${IMAGE_REPO}:${GIT_COMMIT}#g' deploy/*"
                timeout(time: 1, unit: 'MINUTES') {
                    sh "kubectl apply -f deploy/"
                }
            }
        }
    }
    post {
        success {
            echo 'Congratulations!'
            sh """
                curl 'https://oapi.dingtalk.com/robot/send?access_token=ec00a17576b0e07a9ade0f00a26b338f5ae64b3e5b1279a6902934271a7d6b49' \
                    -H 'Content-Type: application/json' \
                    -d '{"msgtype": "text",
                            "text": {
                                "content": "😄👍构建成功👍😄\n 关键字：xdd\n 项目名称: ${JOB_BASE_NAME}\n Commit Id: ${GIT_COMMIT}\n 构建地址：${RUN_DISPLAY_URL}"
                        }
                }'
            """
        }
        failure {
            echo 'Oh no!'
            sh """
                curl 'https://oapi.dingtalk.com/robot/send?access_token=ec00a17576b0e07a9ade0f00a26b338f5ae64b3e5b1279a6902934271a7d6b49' \
                    -H 'Content-Type: application/json' \
                    -d '{"msgtype": "text",
                            "text": {
                                "content": "😖❌构建失败❌😖\n 关键字：xdd\n 项目名称: ${JOB_BASE_NAME}\n Commit Id: ${GIT_COMMIT}\n 构建地址：${RUN_DISPLAY_URL}"
                        }
                }'
            """
        }
        always {
            echo 'I will always say Hello again!'
        }
    }
}
```
> 项目dockerfile要测试没问题才能进行打包进行，否则异常部署需要人为去查找原因

### jenkins利用凭据管理敏感信息
* 凭据管理
* 添加凭据
* 用username password 模式管理token

![3eb53ebeeaa49a7b7ff944da96abd09f.png](evernotecid://43BABE84-B7F2-4A18-86D3-8B26DB0999D2/appyinxiangcom/9859816/ENResource/p66)

* 在jenkin文件中的环境变量里使用credentials("id")来使用
* 优化jenkins 文件
```yaml
    ...
    environment {
        IMAGE_REPO = "172.21.32.13:5000/myblog"
        DINGTALK_CREDS = credentials('dingTalk')
    }
    ...
     curl 'https://oapi.dingtalk.com/robot/send?access_token=${DINGTALK_CREDS_PSW}' \
                    -H 'Content-Type: application/json' \
                    -d '{"msgtype": "text",
                            "text": {
                                "content": "😄👍构建成功👍😄\n 关键字：luffy\n 项目名称: ${JOB_BASE_NAME}\n Commit Id: ${GIT_COMMIT}\n 构建地址：${RUN_DISPLAY_URL}"
                        }
                }'
     ...           
```
## 多分支部署
### 准备
* 检出新分支
* 禁用之前的项目 
* 创建多版本分支任务
![184ac8712e1fb40214fe1b09a462c77b.png](evernotecid://43BABE84-B7F2-4A18-86D3-8B26DB0999D2/appyinxiangcom/9859816/ENResource/p68)
* 分支构建
![c8eb8c973dc3d734ee56268b9a9e4a91.png](evernotecid://43BABE84-B7F2-4A18-86D3-8B26DB0999D2/appyinxiangcom/9859816/ENResource/p69)
* 配置高级克隆的浅克隆 （2层）
* 多分支触发器 （间隔时间1分钟）
### 优化jenkinfile
* 优化消息通知格式
`p6.yaml`
```yaml
pipeline {
    agent { label 'master'}

    environment {
        IMAGE_REPO = "172.27.0.11:5000/demo/myblog"
        DINGTALK_CREDS = credentials('dingTalk')
        TAB_STR = "\n                    \n&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"
    }

    stages {
        stage('printenv') {
            steps {
                script{
                    sh "git log --oneline -n 1 > gitlog.file"
                    env.GIT_LOG = readFile("gitlog.file").trim()
                }
                sh 'printenv'
            }
        }
        stage('checkout') {
            steps {
                checkout scm
                script{
                    env.BUILD_TASKS = env.STAGE_NAME + "√..." + env.TAB_STR
                }
            }
        }
        stage('build-image') {
            steps {
                retry(2) { sh 'docker build . -t ${IMAGE_REPO}:${GIT_COMMIT}'}
                script{
                    env.BUILD_TASKS += env.STAGE_NAME + "√..." + env.TAB_STR
                }
            }
        }
        stage('push-image') {
            steps {
                retry(2) { sh 'docker push ${IMAGE_REPO}:${GIT_COMMIT}'}
                script{
                    env.BUILD_TASKS += env.STAGE_NAME + "√..." + env.TAB_STR
                }
            }
        }
        stage('deploy') {
            steps {
                sh "sed -i 's#{{IMAGE_URL}}#${IMAGE_REPO}:${GIT_COMMIT}#g' deploy/*"
                timeout(time: 1, unit: 'MINUTES') {
                    sh "kubectl apply -f deploy/"
                }
                script{
                    env.BUILD_TASKS += env.STAGE_NAME + "√..." + env.TAB_STR
                }
            }
        }
    }
    post {
        success {
            echo 'Congratulations!'
            sh """
                curl 'https://oapi.dingtalk.com/robot/send?access_token=${DINGTALK_CREDS_PSW}' \
                    -H 'Content-Type: application/json' \
                    -d '{
                        "msgtype": "markdown",
                        "markdown": {
                            "title":"myblog",
                            "text": "😄👍 构建成功 👍😄  \n**项目名称**：xdd  \n**Git log**: ${GIT_LOG}   \n**构建分支**: ${GIT_BRANCH}   \n**构建地址**：${RUN_DISPLAY_URL}  \n**构建任务**：${BUILD_TASKS}"
                        }
                    }'
            """
        }
        failure {
            echo 'Oh no!'
            sh """
                curl 'https://oapi.dingtalk.com/robot/send?access_token=${DINGTALK_CREDS_PSW}' \
                    -H 'Content-Type: application/json' \
                    -d '{
                        "msgtype": "markdown",
                        "markdown": {
                            "title":"myblog",
                            "text": "😖❌ 构建失败 ❌😖  \n**项目名称**：xdd  \n**Git log**: ${GIT_LOG}   \n**构建分支**: ${GIT_BRANCH}  \n**构建地址**：${RUN_DISPLAY_URL}  \n**构建任务**：${BUILD_TASKS}"
                        }
                    }'
            """
        }
        always {
            echo 'I will always say Hello again!'
        }
    }
}
```
* 通知gitlab构建状态
`p7.yaml`
```yaml 
pipeline {
    agent { label 'master'}

    options {
		buildDiscarder(logRotator(numToKeepStr: '10'))
		disableConcurrentBuilds()
		timeout(time: 20, unit: 'MINUTES')
		gitLabConnection('gitlab')
	}

    environment {
        IMAGE_REPO = "172.27.0.11:5000/demo/myblog"
        DINGTALK_CREDS = credentials('dingTalk')
        TAB_STR = "\n                    \n&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"
    }

    stages {
        stage('printenv') {
            steps {
                script{
                    sh "git log --oneline -n 1 > gitlog.file"
                    env.GIT_LOG = readFile("gitlog.file").trim()
                }
                sh 'printenv'
            }
        }
        stage('checkout') {
            steps {
                checkout scm
                updateGitlabCommitStatus(name: env.STAGE_NAME, state: 'success')
                script{
                    env.BUILD_TASKS = env.STAGE_NAME + "√..." + env.TAB_STR
                }
            }
        }
        stage('build-image') {
            steps {
                retry(2) { sh 'docker build . -t ${IMAGE_REPO}:${GIT_COMMIT}'}
                updateGitlabCommitStatus(name: env.STAGE_NAME, state: 'success')
                script{
                    env.BUILD_TASKS += env.STAGE_NAME + "√..." + env.TAB_STR
                }
            }
        }
        stage('push-image') {
            steps {
                retry(2) { sh 'docker push ${IMAGE_REPO}:${GIT_COMMIT}'}
                updateGitlabCommitStatus(name: env.STAGE_NAME, state: 'success')
                script{
                    env.BUILD_TASKS += env.STAGE_NAME + "√..." + env.TAB_STR
                }
            }
        }
        stage('deploy') {
            steps {
                sh "sed -i 's#{{IMAGE_URL}}#${IMAGE_REPO}:${GIT_COMMIT}#g' deploy/*"
                timeout(time: 1, unit: 'MINUTES') {
                    sh "kubectl apply -f deploy/"
                }
                updateGitlabCommitStatus(name: env.STAGE_NAME, state: 'success')
                script{
                    env.BUILD_TASKS += env.STAGE_NAME + "√..." + env.TAB_STR
                }
            }
        }
    }
    post {
        success {
            echo 'Congratulations!'
            sh """
                curl 'https://oapi.dingtalk.com/robot/send?access_token=${DINGTALK_CREDS_PSW}' \
                    -H 'Content-Type: application/json' \
                    -d '{
                        "msgtype": "markdown",
                        "markdown": {
                            "title":"myblog",
                            "text": "😄👍 构建成功 👍😄  \n**项目名称**：xdd  \n**Git log**: ${GIT_LOG}   \n**构建分支**: ${BRANCH_NAME}   \n**构建地址**：${RUN_DISPLAY_URL}  \n**构建任务**：${BUILD_TASKS}"
                        }
                    }'
            """
        }
        failure {
            echo 'Oh no!'
            sh """
                curl 'https://oapi.dingtalk.com/robot/send?access_token=${DINGTALK_CREDS_PSW}' \
                    -H 'Content-Type: application/json' \
                    -d '{
                        "msgtype": "markdown",
                        "markdown": {
                            "title":"myblog",
                            "text": "😖❌ 构建失败 ❌😖  \n**项目名称**：xdd  \n**Git log**: ${GIT_LOG}   \n**构建分支**: ${BRANCH_NAME}  \n**构建地址**：${RUN_DISPLAY_URL}  \n**构建任务**：${BUILD_TASKS}"
                        }
                    }'
            """
        }
        always {
            echo 'I will always say Hello again!'
        }
    }

```
## 通过k8s自动构建jenkins工作节点
### 安装k8s插件
* 安装kubernetes插件
![8535a23844fef292962f073e683724d5.png](evernotecid://43BABE84-B7F2-4A18-86D3-8B26DB0999D2/appyinxiangcom/9859816/ENResource/p70)
* 重启jenkins 
```sh
kj delete po jenkins-master-0
```
* 系统管理--系统配置--底部
![33e1632b79a3069ffde2c2a67447c9dc.png](evernotecid://43BABE84-B7F2-4A18-86D3-8B26DB0999D2/appyinxiangcom/9859816/ENResource/p71)
* 查看kubeapi 地址
```sh
 kubectl get node -v=7
```
> 可以通过ip进行访问，也可以根据k8s的跨namespace的服务发现来做
>  https://172.27.0.11:6443
>  https://kubernetes.default
* 配置jenkins 地址，也使用k8s内部发现 
    * http://jenkins:8080
* 配置通道
    * jenkins:50000
* 配置pod模板
    * 名称: jnlp-slave
    * 名命名空间: jenkins
    * 标签列表: jnlp-slave
    * 节点选择器
        * 配置节点 agent=true
    * 工作空间卷 配置hostPath
        * /opt/jenkins_jobs
* node打标签
```sh
kubectl label node k8s-slave1 agent=true
```
* 文件目录权限
```sh
chown -R 1000:1000 /opt/jenkins_jobs
```
* 回放测试将节点改为jnlp-slave
> 构建失败因为pod内部没有docker命令和kubectl命令

### 自定义slave pod
* 制作tool镜像用来实现常用功能
```Dockerfile
FROM alpine
LABEL maintainer="inspur_lyx@hotmail.com"
USER root

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apk/repositories && \
    apk update && \
    apk add  --no-cache openrc docker git curl tar gcc g++ make \
    bash shadow openjdk8 python3 python3-dev py-pip openssl-dev libffi-dev \
    libstdc++ harfbuzz nss freetype ttf-freefont chromium chromium-chromedriver && \
    mkdir -p /root/.kube && \
    usermod -a -G docker root

COPY requirements.txt /
COPY config /root/.kube/

RUN pip install -i http://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com -r /requirements.txt

RUN rm -rf /var/cache/apk/* && \
    rm -rf ~/.cache/pip
#-----------------安装 kubectl--------------------#
COPY kubectl /usr/local/bin/
RUN chmod +x /usr/local/bin/kubectl
# ------------------------------------------------#
```
* 准备工作
```sh
 cp /usr/bin/kubectl .
 cp ~/.kube/config .
 
 #requirements.txt rf文件
robotframework
robotframework-seleniumlibrary
robotframework-databaselibrary
robotframework-requests
```
* 构建镜像
```sh
docker build . -t 172.27.0.11:5000/devops/tools:v1
docker push 172.27.0.11:5000/devops/tools:v1
```
* 测试镜像
```sh
 docker run -it 172.27.0.11:5000/devops/tools:v1 bash
 docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -it 172.27.0.11:5000/devops/tools:v1 bash
```
> docker 中不能执行启动docker 
* 使用多pod执行任务
![f7cb1ed7ff35d941fc8a269b46f54bfd.png](evernotecid://43BABE84-B7F2-4A18-86D3-8B26DB0999D2/appyinxiangcom/9859816/ENResource/p73)
> 添加容器会覆盖原来的pod模板需要将原来模板加回来
> jenkins/inbound-agent:4.3-4
* 配置多容器
`tools 容器`
![c7c976d1f0fa4bd68a79ddb16779d7a4.png](evernotecid://43BABE84-B7F2-4A18-86D3-8B26DB0999D2/appyinxiangcom/9859816/ENResource/p75)
`slave 容器`
![4f9bd2a5763f0b2dd107e1471031d47b.png](evernotecid://43BABE84-B7F2-4A18-86D3-8B26DB0999D2/appyinxiangcom/9859816/ENResource/p74)

* 改造jenkinsfile
`p8.yaml`
```yaml
pipeline {
    agent { label 'jnlp-slave'}

    options {
		buildDiscarder(logRotator(numToKeepStr: '10'))
		disableConcurrentBuilds()
		timeout(time: 20, unit: 'MINUTES')
		gitLabConnection('gitlab')
	}

    environment {
        IMAGE_REPO = "172.27.0.11:5000/myblog"
        DINGTALK_CREDS = credentials('dingTalk')
        TAB_STR = "\n                    \n&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"
    }

    stages {
        stage('printenv') {
            steps {
                script{
                    sh "git log --oneline -n 1 > gitlog.file"
                    env.GIT_LOG = readFile("gitlog.file").trim()
                }
                sh 'printenv'
            }
        }
        stage('checkout') {
            steps {
                container('tools') {
                    checkout scm
                }
                updateGitlabCommitStatus(name: env.STAGE_NAME, state: 'success')
                script{
                    env.BUILD_TASKS = env.STAGE_NAME + "√..." + env.TAB_STR
                }
            }
        }
        stage('build-image') {
            steps {
                container('tools') {
                    retry(2) { sh 'docker build . -t ${IMAGE_REPO}:${GIT_COMMIT}'}
                }
                updateGitlabCommitStatus(name: env.STAGE_NAME, state: 'success')
                script{
                    env.BUILD_TASKS += env.STAGE_NAME + "√..." + env.TAB_STR
                }
            }
        }
        stage('push-image') {
            steps {
                container('tools') {
                    retry(2) { sh 'docker push ${IMAGE_REPO}:${GIT_COMMIT}'}
                }
                updateGitlabCommitStatus(name: env.STAGE_NAME, state: 'success')
                script{
                    env.BUILD_TASKS += env.STAGE_NAME + "√..." + env.TAB_STR
                }
            }
        }
        stage('deploy') {
            steps {
                container('tools') {
                    sh "sed -i 's#{{IMAGE_URL}}#${IMAGE_REPO}:${GIT_COMMIT}#g' deploy/*"
                    timeout(time: 1, unit: 'MINUTES') {
                        sh "kubectl apply -f deploy/"
                    }
                }
                updateGitlabCommitStatus(name: env.STAGE_NAME, state: 'success')
                script{
                    env.BUILD_TASKS += env.STAGE_NAME + "√..." + env.TAB_STR
                }
            }
        }
    }
    post {
        success {
            echo 'Congratulations!'
            sh """
                curl 'https://oapi.dingtalk.com/robot/send?access_token=${DINGTALK_CREDS_PSW}' \
                    -H 'Content-Type: application/json' \
                    -d '{
                        "msgtype": "markdown",
                        "markdown": {
                            "title":"myblog",
                            "text": "😄👍 构建成功 👍😄  \n**项目名称**：xdd  \n**Git log**: ${GIT_LOG}   \n**构建分支**: ${BRANCH_NAME}   \n**构建地址**：${RUN_DISPLAY_URL}  \n**构建任务**：${BUILD_TASKS}"
                        }
                    }'
            """
        }
        failure {
            echo 'Oh no!'
            sh """
                curl 'https://oapi.dingtalk.com/robot/send?access_token=${DINGTALK_CREDS_PSW}' \
                    -H 'Content-Type: application/json' \
                    -d '{
                        "msgtype": "markdown",
                        "markdown": {
                            "title":"myblog",
                            "text": "😖❌ 构建失败 ❌😖  \n**项目名称**：xdd  \n**Git log**: ${GIT_LOG}   \n**构建分支**: ${BRANCH_NAME}  \n**构建地址**：${RUN_DISPLAY_URL}  \n**构建任务**：${BUILD_TASKS}"
                        }
                    }'
            """
        }
        always {
            echo 'I will always say Hello again!'
        }
    }
}
```