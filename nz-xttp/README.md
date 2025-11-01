version: '3.8'

services:
  app:
    image: leojyenn/nz-xttp
    ports:
      - "7860:7860"
    environment:
      - UUID=自定义UUID
      - DOMAIN=提供的域名
      - NZ_SERVER=哪吒v1地址
      - NZ_CLIENT_SECRET=哪吒密钥
      - NZ_TLS=true



  格式 
  vless://9afe736b-6866-4e5d-92b1-b8404498744b@google.com:443?encryption=none&security=tls&fp=chrome&type=xhttp&path=%2F&mode=auto#-xhttp
