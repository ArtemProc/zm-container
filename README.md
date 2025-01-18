# zm-container

created based on the original entrypoint.sh from https://github.com/ZoneMinder/zmdockerfiles/blob/master/utils/entrypoint.sh

Based image for container Ubuntu 22.04

It is possible to run with docker compose with external DB from mariad:11.2.6 image (no changes)

The default docker-compose_env.yaml configured to run with separate Maria DB instance in container mysql_cont linked to zoneminder

You can build your own image and push to docker hub and adjust the .env file


Start container

docker compose -f docker-compose_env.yaml --env-file .env up
