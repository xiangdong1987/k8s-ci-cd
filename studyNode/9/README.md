[TOC]
## Jenkins 接入 SonarQube
### 工作原理
* sonarqube代码检测工具 
    * SonarQube Scaner 扫描本地代码
    * 执行完成后将报告上传给服务端
    * 服务端保存报告，并通过UI展示
    * 使用postgresSql数据库
### 准备阶段
1. 资源文件
`secret.yaml`
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sonar
  namespace: jenkins
type: Opaque
data:
  POSTGRES_USER: cm9vdA==	# root
  POSTGRES_PASSWORD: MTIzNDU2	# 123456
```
`postgres.yaml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: sonar-postgres
  labels:
    app: sonar-postgres
  namespace: jenkins
spec:
  ports:
  - name: server
    port: 5432
    targetPort: 5432
    protocol: TCP
  selector:
    app: sonar-postgres
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: jenkins
  name: sonar-postgres
  labels:
    app: sonar-postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sonar-postgres
  template:
    metadata:
      labels:
        app: sonar-postgres
    spec:
      nodeSelector:
        sonar: "true"
      tolerations:
      - operator: "Exists"
      containers:
      - name: postgres
        image:  postgres:11.4
        imagePullPolicy: "IfNotPresent"
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB             #PostgreSQL 数据库名称
          value: "sonar"
        - name: POSTGRES_USER           #PostgreSQL 用户名
          valueFrom:
            secretKeyRef:
              name: sonar
              key: POSTGRES_USER
        - name: POSTGRES_PASSWORD       #PostgreSQL 密码
          valueFrom:
            secretKeyRef:
              name: sonar
              key: POSTGRES_PASSWORD
        resources:
          limits:
            cpu: 1000m
            memory: 2048Mi
          requests:
            cpu: 500m
            memory: 1024Mi
        volumeMounts:
        - mountPath: /var/lib/postgresql/data
          name: postgredb
      volumes:
      - name: postgredb
        hostPath:
          path: /var/lib/postgres/
          type: Directory
```
`sonar.yaml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: sonarqube
  namespace: jenkins
  labels:
    app: sonarqube
spec:
  ports:
  - name: sonarqube
    port: 9000
    targetPort: 9000
    protocol: TCP
  selector:
    app: sonarqube
---
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: jenkins
  name: sonarqube
  labels:
    app: sonarqube
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sonarqube
  template:
    metadata:
      labels:
        app: sonarqube
    spec:
      nodeSelector:
        sonar: "true"
      initContainers:
      - command:
        - /sbin/sysctl
        - -w
        - vm.max_map_count=262144
        image: alpine:3.6
        imagePullPolicy: IfNotPresent
        name: elasticsearch-logging-init
        resources: {}
        securityContext:
          privileged: true
      containers:
      - name: sonarqube
        image: sonarqube:7.9-community
        ports:
        - containerPort: 9000
        env:
        - name: SONARQUBE_JDBC_USERNAME
          valueFrom:
            secretKeyRef:
              name: sonar
              key: POSTGRES_USER
        - name: SONARQUBE_JDBC_PASSWORD
          valueFrom:
            secretKeyRef:
              name: sonar
              key: POSTGRES_PASSWORD
        - name: SONARQUBE_JDBC_URL
          value: "jdbc:postgresql://sonar-postgres:5432/sonar"
        livenessProbe:
          httpGet:
            path: /sessions/new
            port: 9000
          initialDelaySeconds: 60
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /sessions/new
            port: 9000
          initialDelaySeconds: 60
          periodSeconds: 30
          failureThreshold: 6
        resources:
          limits:
            cpu: 2000m
            memory: 4096Mi
          requests:
            cpu: 300m
            memory: 512Mi
      volumes:
      - name: sonarqube-data
        hostPath:
          path: /opt/sonarqube/data
      - name: sonarqube-logs
        hostPath:
          path: /opt/sonarqube/logs
---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: sonarqube
  namespace: jenkins
spec:
  rules:
  - host: sonar.qq.com
    http:
      paths:
      - backend:
          serviceName: sonarqube
          servicePort: 9000
        path: /
status:
  loadBalancer: {}
```
2. 安装服务端
```sh
# 秘钥文件
kubectl create -f secret.yaml
# 指定node
kubectl label node k8s-slave1 sonar=true
# 创建目录
mkdir /var/lib/postgres/
# 创建数据库
kubectl create -f postgres.yaml
# 创建服务器
kubectl create -f sonar.yaml
# 配置本地host
139.155.240.61 sonar.qq.com
# 访问后端界面
http://sonar.qq.com
username :admin
password :admin
```
3. sonar scaner 安装
https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-4.2.0.1873-linux.zip
4. 演示扫描文件:放在代码目录
`sonar-project.properties`
```properties
sonar.projectKey=myblog
sonar.projectName=myblog

sonar.coverage.dtdVerification=false

sonar.source=.
```
5. 配置sonarqube scanner 的上报服务地址
`/sonar-scanner/conf/sonar-scanner.properties`
```properties
#Configure here general information about the environment, such as SonarQube server connection details for example
#No information about specific project should appear here

#----- Default SonarQube server
sonar.host.url=http://10.102.205.44:9000

#----- Default source code encoding
#sonar.sourceEncoding=UTF-8
```
6. 去代码目录执行命令
```sh
/opt/demo-resources/sonar/sonar-scanner/bin/sonar-scanner -X
```
### sonarqube集成到tools镜像中
1. 使用tools镜像继承sonarqube
2. 修改客户端配置使用service发现
```properties
sonar.host.url=http://sonarqube:9000
```
3. 删除sanner的jre简化sanner
    * 删除jre文件
    * 修改sanner脚本,不使用自带jre
    `bin/sonar-scanner`
    ```sh
       use_embedded_jre=false
    ```
4. 修改tools镜像
`Dockerfile2.yaml`
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

#---------------安装 sonar-scanner-----------------#
COPY sonar-scanner /usr/lib/sonar-scanner
RUN ln -s /usr/lib/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner && chmod +x /usr/local/bin/sonar-scanner
ENV SONAR_RUNNER_HOME=/usr/lib/sonar-scanner
# ------------------------------------------------#
```
5. 构建和推送新镜像
```sh
# 拷贝sanner
cp -R /opt/demo-resources/sonar/sonar-scanner 
sonar-scanner/
# 构建镜像
docker build -t 172.27.0.11:5000/devops/tools:v2 .
# 推送镜像
docker push 172.27.0.11:5000/devops/tools:v2
```
6. jenkins改造修改tools 
7. jenkins安装sonar插件
    * SonarQube Scanner安装
    * jenkins添加凭证
    ![954c1c41074c0f94097a9b3acbb9ebb6.png](evernotecid://43BABE84-B7F2-4A18-86D3-8B26DB0999D2/appyinxiangcom/9859816/ENResource/p79)
    
    * 配置SonarQube Scanner
    ![96da1a27f2ec4fa917ba87037714e291.png](evernotecid://43BABE84-B7F2-4A18-86D3-8B26DB0999D2/appyinxiangcom/9859816/ENResource/p77)
8. 项目需要    
`sonar-project.properties`
```properties
sonar.projectKey=myblog
sonar.projectName=myblog

sonar.coverage.dtdVerification=false

sonar.source=.
```
9. Jenkinsfile集成sonar
`p9.yaml`
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
        IMAGE_REPO = "172.27.0.11:5000/demo/myblog"
        DINGTALK_CREDS = credentials('dingTalk')
        TAB_STR = "\n                    \n&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"
    }

    stages {
        stage('git-log') {
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
        stage('CI'){
            failFast true
            parallel {
                stage('Unit Test') {
                    steps {
                        echo "Unit Test Stage Skip..."
                    }
                }
                stage('Code Scan') {
                    steps {
                        container('tools') {
                            withSonarQubeEnv('sonarqube') {
                                sh 'sonar-scanner -X'
                                sleep 3
                            }
                            script {
                                timeout(1) {
                                    def qg = waitForQualityGate('sonarqube')
                                    if (qg.status != 'OK') {
                                        error "未通过Sonarqube的代码质量阈检查，请及时修改！failure: ${qg.status}"
                                    }
                                }
                            }
                        }
                    }
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
## 集成RobotFramework实现验收测试
### 准备
1. 安装RobotFramework (tools镜像中已经包含)
2. 与jenkins集成，安装RobotFramework插件
3. Jenkinsfile 集成RobotFramework
`p10.yaml`
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
        IMAGE_REPO = "172.27.0.11:5000/demo/myblog"
        DINGTALK_CREDS = credentials('dingTalk')
        TAB_STR = "\n                    \n&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"
    }

    stages {
        stage('git-log') {
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
        stage('CI'){
            failFast true
            parallel {
                stage('Unit Test') {
                    steps {
                        echo "Unit Test Stage Skip..."
                    }
                }
                stage('Code Scan') {
                    steps {
                        container('tools') {
                            withSonarQubeEnv('sonarqube') {
                                sh 'sonar-scanner -X'
                                sleep 3
                            }
                            script {
                                timeout(1) {
                                    def qg = waitForQualityGate('sonarqube')
                                    if (qg.status != 'OK') {
                                        error "未通过Sonarqube的代码质量阈检查，请及时修改！failure: ${qg.status}"
                                    }
                                }
                            }
                        }
                    }
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
        stage('Accept Test') {
            steps {
                    container('tools') {
                        sh 'robot -i critical  -d artifacts/ robot.txt|| echo ok'
                        echo "R ${currentBuild.result}"
                        step([
                            $class : 'RobotPublisher',
                            outputPath: 'artifacts/',
                            outputFileName : "output.xml",
                            disableArchiveOutput : false,
                            passThreshold : 40,
                            unstableThreshold: 20.0,
                            onlyCritical : true,
                            otherFiles : "*.png"
                        ])
                        echo "R ${currentBuild.result}"
                        archiveArtifacts artifacts: 'artifacts/*', fingerprint: true
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
> Jenkinsfile 中的配置来集成RobotFramework
4. 编写测试用例
`robot.txt`
```sh
*** Settings ***
Library           RequestsLibrary
Library           SeleniumLibrary

*** Variables ***
${demo_url}       http://myblog.demo/blog/index

*** Test Cases ***
api
    [Tags]  critical
    Create Session    api    ${demo_url}
    ${alarm_system_info}    RequestsLibrary.Get Request    api    /
    log    ${alarm_system_info.status_code}
    log    ${alarm_system_info.content}
    should be true    ${alarm_system_info.status_code} == 200

ui
    [Tags]  critical
    open browser    ${demo_url}/    headlesschrome    None    False    None    None add_argument("--no-sandbox")
    sleep    2s
    Page Should Contain    blog!
    close browser
```