# VLESS (xhttp) + 哪吒探针 
镜像leojyenn/nz-xttp

## docker-compose.yml


```javascript
version: '3.8'

services:
  app:
    image: leojyenn/nz-xttp
    environment:
      - UUID=自定义UUID
      - NEZHA_SERVER=哪吒v1地址
      - NEZHA_KEY=哪吒密钥
    restart: always
```

## 格式示例

```javascript
vless://自定义UUID@提供的域名:443?encryption=none&security=tls&fp=chrome&type=xhttp&path=%2F&mode=auto#-xhttp
```
