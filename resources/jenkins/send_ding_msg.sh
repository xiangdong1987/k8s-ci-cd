curl 'https://oapi.dingtalk.com/robot/send?access_token=8ca19c49673df02df3c1c3b9b2602f223f3aabaac004b5800eb4b12e89b22a52' \
   -H 'Content-Type: application/json' \
   -d '{"msgtype": "text", 
        "text": {
             "content": "我就是我, 是不一样的烟火,myblog"
        }
      }'

curl 'https://oapi.dingtalk.com/robot/send?access_token=8ca19c49673df02df3c1c3b9b2602f223f3aabaac004b5800eb4b12e89b22a52' \
   -H 'Content-Type: application/json' \
   -d '{
     "msgtype": "markdown",
     "markdown": {
         "title":"myblog",
         "text": "<font color=\"info\">😄👍 ${title} 👍😄</font>  \n  **Git log**: fix sync err   \n  **Git branch**: master  \n  **Build Tasks**: checkout..."
     }
 }'