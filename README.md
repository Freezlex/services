`sudo docker compose $(find -name 'docker-compose*.yml' -type f -printf '%p\t%d\n'  2>/dev/null | sort -n -k2 | cut -f 1 | awk '{print "-f "$0}') up --build`

`sudo docker compose -f certbot/manual.docker-compose.certbot.yml run --rm  certbot certonly --webroot --webroot-path /var/www/certbot/ -d freezlex.dev`