FROM 172.27.0.11:5000/centos-python3-nginx:v1

#MAINTAINER 维护者信息
LABEL maintainer="inspur_lyx@hotmail.com"

#工作目录
WORKDIR /opt/myblog

#拷贝文件至工作目录
COPY . .

RUN cp myblog.conf /usr/local/nginx/conf/myblog.conf && cp uwsgi_params /usr/local/nginx/conf/uwsgi_params

#安装依赖的插件
RUN pip3 install -i http://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com -r requirements.txt

RUN chmod +x run.sh && rm -rf ~/.cache/pip

#EXPOSE 映射端口
EXPOSE 8002

#容器启动时执行命令
CMD ["./run.sh"]
