Lancer les services :
`sudo docker compose $(find -name 'docker-compose*.yml' -type f -printf '%p\t%d\n'  2>/dev/null | sort -n -k2 | cut -f 1 | awk '{print "-f "$0}') up --build`

Ajouter un utilisateur admin à Traefik :
`echo "USERS=$(htpasswd -nB $USER)" >> .env`