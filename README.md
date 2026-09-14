# Nginx Proxy

Docker 기반의 공용 Nginx Reverse Proxy 및 HTTPS 인프라입니다.

각 서비스의 애플리케이션을 개별 Docker Compose 프로젝트로 관리하면서, 외부에서는 하나의 Nginx를 통해 접근하도록 구성합니다.

## 1. 목적

이 프로젝트의 주요 목적은 다음과 같습니다.

* 여러 Docker 서비스의 외부 진입점 통합
* Nginx Reverse Proxy를 통한 서비스 라우팅
* Let's Encrypt를 이용한 HTTPS 적용
* Certbot을 이용한 SSL 인증서 자동 갱신
* 각 서비스의 애플리케이션 포트를 외부에 직접 노출하지 않는 구조 구성
* 공용 Docker Network를 이용한 서비스 간 연결
* 새로운 서비스를 추가할 때 기존 Reverse Proxy 인프라를 재사용

---

## 2. 전체 구조

현재 운영 환경은 다음과 같은 구조입니다.

```text
                         Internet
                            │
                       :80 / :443
                            │
                            ▼
                    ┌────────────────┐
                    │  nginx-proxy   │
                    │                │
                    │ Reverse Proxy  │
                    │ HTTPS / SSL    │
                    └───────┬────────┘
                            │
                     proxy-network
                            │
                 ┌──────────┴──────────┐
                 │                     │
                 ▼                     ▼
          ┌─────────────┐       ┌─────────────┐
          │  blog-app   │       │ other-api   │
          │   :3000     │       │   :3000     │
          └──────┬──────┘       └─────────────┘
                 │
            blog-network
                 │
                 ▼
          ┌─────────────┐
          │blog-postgres│
          │   :5432     │
          └─────────────┘
```

핵심은 **Nginx만 외부에 포트를 공개하고 애플리케이션과 데이터베이스는 Docker 내부 네트워크에서 통신한다는 것**입니다.

외부에서는 다음과 같이 접근합니다.

```text
Internet
   │
   ▼
https://upseul.mooo.com
   │
   ▼
nginx-proxy
   │
   ▼
blog-app:3000
```

Blog Backend의 `3000` 포트와 PostgreSQL의 `5432` 포트는 호스트에 직접 공개하지 않습니다.

---

# 3. Docker Network 구조

서비스 간 연결을 위해 `proxy-network`라는 외부 Docker Network를 사용합니다.

```text
proxy-network
│
├── nginx-proxy
├── blog-app
└── 기타 외부 공개가 필요한 서비스
```

각 서비스는 자신의 Compose 프로젝트에서 관리할 수 있으며, Nginx와 연결해야 하는 서비스만 `proxy-network`에 연결합니다.

예를 들어 Blog Backend의 경우:

```text
blog-app
 ├── blog-network
 │      └── blog-postgres
 │
 └── proxy-network
        └── nginx-proxy
```

이 구조를 통해 Blog Backend와 PostgreSQL의 내부 네트워크를 분리할 수 있습니다.

### 중요

`blog-postgres`는 `proxy-network`에 연결하지 않습니다.

PostgreSQL은 Blog Backend에서만 접근하면 되므로 다음과 같이 구성합니다.

```text
nginx-proxy
     │
     │ proxy-network
     ▼
 blog-app
     │
     │ blog-network
     ▼
blog-postgres
```

즉, 외부 요청이 데이터베이스까지 직접 접근할 수 있는 경로를 만들지 않습니다.

---

# 4. Reverse Proxy 라우팅

현재 Blog Backend는 다음과 같이 연결되어 있습니다.

```nginx
location / {
    proxy_pass http://blog-app:3000;

    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

따라서:

```text
https://upseul.mooo.com/posts
```

요청이 들어오면:

```text
Client
  ↓
Nginx
  ↓
blog-app:3000
  ↓
/posts
```

로 전달됩니다.

---

# 5. 새로운 서비스 추가

이 프로젝트의 중요한 목적 중 하나는 **새로운 서비스를 추가할 때 Nginx를 다시 구축하지 않는 것**입니다.

새로운 API 서버가 추가된다면:

```text
Nginx Proxy
     │
     ├── Blog Backend
     │
     ├── New API
     │
     └── Game Server
```

와 같이 기존 `proxy-network`에 서비스를 연결하고 Nginx 설정만 추가하면 됩니다.

---

# 6. 서비스 접근 방식

서비스가 여러 개로 증가하면 크게 두 가지 방식으로 구성할 수 있습니다.

## 6.1 Path 기반 라우팅

하나의 도메인을 사용하면서 URL 경로로 서비스를 구분합니다.

```text
https://upseul.mooo.com/
https://upseul.mooo.com/api/
https://upseul.mooo.com/game/
```

예를 들어:

```nginx
server {
    listen 443 ssl;
    server_name upseul.mooo.com;

    location / {
        proxy_pass http://blog-app:3000;
    }

    location /api/ {
        proxy_pass http://new-api:3000;
    }

    location /game/ {
        proxy_pass http://game-server:3000;
    }
}
```

이 방식은 하나의 도메인에서 여러 서비스를 제공할 때 사용할 수 있습니다.

단, `proxy_pass`의 URI 설정에 따라 백엔드로 전달되는 경로가 달라질 수 있으므로 설정 시 주의해야 합니다.

---

# 7. Subdomain 기반 라우팅

서비스가 서로 독립적인 프로젝트라면 서브도메인 방식도 사용할 수 있습니다.

예:

```text
Blog
https://upseul.mooo.com

API
https://api.upseul.mooo.com

Game
https://game.upseul.mooo.com
```

Nginx에서는 서비스별로 `server` 블록을 분리합니다.

```nginx
server {
    listen 443 ssl;
    server_name upseul.mooo.com;

    location / {
        proxy_pass http://blog-app:3000;
    }
}

server {
    listen 443 ssl;
    server_name api.upseul.mooo.com;

    location / {
        proxy_pass http://new-api:3000;
    }
}

server {
    listen 443 ssl;
    server_name game.upseul.mooo.com;

    location / {
        proxy_pass http://game-server:3000;
    }
}
```

이 구조에서는 서비스마다 URL 공간이 완전히 분리됩니다.

---

# 8. 어떤 방식을 사용할 것인가?

현재 Nginx Proxy는 여러 독립 프로젝트에서 재사용하는 공용 Reverse Proxy이므로, 서비스의 성격에 따라 방식을 선택합니다.

### 하나의 서비스 내부 API를 분리하는 경우

Path 기반을 사용할 수 있습니다.

```text
upseul.mooo.com
└── /api
```

### 서로 독립적인 서비스인 경우

Subdomain 방식을 권장합니다.

```text
upseul.mooo.com       → Blog
api.upseul.mooo.com   → API
game.upseul.mooo.com  → Game
```

특히 서로 다른 프로젝트가 각각 독립적으로 개발 및 배포된다면 Subdomain 방식이 관리하기 편합니다.

---

# 9. 새로운 서비스를 추가하는 방법

새로운 서비스가 추가되었을 때의 기본 절차는 다음과 같습니다.

## 9.1 Docker Compose에 `proxy-network` 연결

새로운 서비스의 Compose에서:

```yaml
services:
  api:
    ...
    networks:
      - default
      - proxy-network

networks:
  proxy-network:
    external: true
```

서비스가 기존 `proxy-network`에 연결되도록 합니다.

---

## 9.2 Nginx 설정 추가

예를 들어 새로운 API 컨테이너 이름이 `new-api`라면:

```nginx
server {
    listen 443 ssl;
    server_name api.upseul.mooo.com;

    ssl_certificate /etc/letsencrypt/live/upseul.mooo.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/upseul.mooo.com/privkey.pem;

    location / {
        proxy_pass http://new-api:3000;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

단, 실제 운영 시에는 해당 서비스에 맞는 인증서 및 도메인 설정이 필요합니다.

---

## 9.3 Nginx 설정 검사

설정을 변경한 후 바로 reload하지 않고 먼저 문법을 검사합니다.

```bash
docker exec nginx-proxy nginx -t
```

정상이라면:

```text
syntax is ok
test is successful
```

가 출력됩니다.

---

## 9.4 Nginx Reload

설정에 문제가 없다면:

```bash
docker exec nginx-proxy nginx -s reload
```

을 실행합니다.

Nginx 컨테이너를 재생성하지 않고 새로운 설정을 적용할 수 있습니다.

---

# 10. 서비스 추가 시 주의사항

## Docker Network

Nginx와 새로운 서비스가 반드시 같은 Docker Network에 있어야 합니다.

```text
nginx-proxy
     │
     └── proxy-network
             │
             └── new-api
```

같은 네트워크에 연결되어 있지 않으면 Nginx에서 다음과 같은 오류가 발생할 수 있습니다.

```text
host not found in upstream
```

예:

```text
host not found in upstream "new-api"
```

이 경우 먼저:

```bash
docker network inspect proxy-network
```

를 실행하여 해당 서비스가 네트워크에 연결되어 있는지 확인합니다.

---

## 컨테이너 이름

Nginx의 `proxy_pass`에 사용하는 이름은 Docker Network 내부에서 실제로 DNS 조회가 가능한 이름이어야 합니다.

예:

```nginx
proxy_pass http://new-api:3000;
```

그렇다면 Docker Network에서 `new-api`라는 이름으로 해당 컨테이너를 찾을 수 있어야 합니다.

서비스 이름 또는 `container_name`을 사용할 경우 실제 Compose 설정을 기준으로 확인해야 합니다.

---

# 11. 외부 포트 공개 원칙

새로운 서비스를 추가한다고 해서 애플리케이션 포트를 서버에 직접 공개할 필요는 없습니다.

권장 구조:

```yaml
services:
  api:
    expose:
      - "3000"
```

그리고:

```text
Internet
   │
   ▼
Nginx :443
   │
   ▼
api:3000
```

으로 접근합니다.

가급적 다음과 같은 구조는 사용하지 않습니다.

```yaml
ports:
  - "3000:3000"
```

이렇게 하면 서버의 `3000` 포트가 외부에 직접 노출될 수 있습니다.

---

# 12. HTTPS 및 Certbot

HTTPS는 Let's Encrypt 인증서를 사용합니다.

구조:

```text
                    Let's Encrypt
                         │
                         ▼
                    Certbot
                         │
                         ▼
                 /etc/letsencrypt
                         │
                         ▼
                     Nginx
                         │
                         ▼
                    HTTPS :443
```

Certbot은 컨테이너 내부에서 주기적으로:

```bash
certbot renew
```

을 실행하여 인증서 갱신 여부를 확인합니다.

현재 구성에서는 12시간 간격으로 갱신 여부를 확인합니다.

인증서가 아직 갱신 대상이 아니라면 실제 갱신은 수행하지 않습니다.

---

# 13. 현재 디렉터리 구조

```text
nginx-proxy/
├── docker-compose.yml
├── nginx/
│   └── conf.d/
│       └── blog.conf
└── certbot/
    ├── conf/
    │   └── .gitkeep
    └── www/
        └── .gitkeep
```

`certbot/conf`에는 Let's Encrypt 인증서와 개인키가 생성되므로 Git에 커밋하지 않습니다.

특히 다음과 같은 파일은 외부에 공개하면 안 됩니다.

```text
privkey.pem
```

따라서 인증서 관련 실제 생성 파일은 `.gitignore`로 관리합니다.

---

# 14. 현재 운영 구조 요약

현재 서버의 주요 네트워크 구조는 다음과 같습니다.

```text
                         Internet
                            │
                     HTTP :80 / HTTPS :443
                            │
                            ▼
                    ┌────────────────┐
                    │  nginx-proxy   │
                    │                │
                    │ Reverse Proxy  │
                    │     HTTPS      │
                    └───────┬────────┘
                            │
                     proxy-network
                            │
                 ┌──────────┴──────────┐
                 │                     │
                 ▼                     ▼
          ┌─────────────┐       ┌─────────────┐
          │  blog-app   │       │  new-api    │
          │   :3000     │       │   :3000     │
          └──────┬──────┘       └─────────────┘
                 │
            blog-network
                 │
                 ▼
          ┌─────────────┐
          │blog-postgres│
          │   :5432     │
          └─────────────┘
```

외부에서 직접 접근 가능한 서비스는 Nginx로 제한하고, 애플리케이션 및 데이터베이스는 Docker Network를 통해 내부 통신하도록 구성합니다.

---

# 15. 핵심 원칙

이 프로젝트의 운영 구조를 이해할 때 다음 원칙을 기준으로 합니다.

1. **Nginx는 공용 Reverse Proxy로 사용한다.**
2. **각 애플리케이션은 독립적인 Docker Compose 프로젝트로 관리한다.**
3. **외부 공개가 필요한 서비스만 `proxy-network`에 연결한다.**
4. **데이터베이스는 Reverse Proxy Network에 연결하지 않는다.**
5. **애플리케이션의 포트를 가급적 호스트에 직접 공개하지 않는다.**
6. **외부 HTTP/HTTPS 진입점은 Nginx로 통합한다.**
7. **새 서비스 추가 시 기존 Nginx Proxy를 재사용한다.**
8. **Nginx 설정 변경 전 `nginx -t`로 검증한다.**
9. **검증 후 `nginx -s reload`로 설정을 반영한다.**
10. **Let's Encrypt 인증서와 개인키는 Git에 커밋하지 않는다.**

이 구조를 기반으로 향후 Blog Backend, 새로운 API, 게임 서버 등의 서비스를 하나의 Nginx 인프라에서 독립적으로 운영할 수 있습니다.
