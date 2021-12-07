#!/bin/bash

REGION="us-east-1"
VPC=$(aws ec2 describe-vpcs \
    --filter "Name=is-default,Values=true" \
    --query Vpcs[0].VpcId \
    --output text)
ZONE=$(aws ec2 describe-availability-zones \
    --filter "Name=region-name,Values=$REGION" \
    --query AvailabilityZones[0].ZoneId \
    --output text)
SUBNET=$(aws ec2 describe-subnets \
    --filter Name=vpc-id,Values=$VPC Name=availability-zone-id,Values=$ZONE \
    --query Subnets[0].SubnetId \
    --output text)

#https://docs.docker.com/engine/swarm/swarm-tutorial/#three-networked-host-machines
i=1;
while [ $i -le $1 ] 
do
    docker-machine create \
        --driver=amazonec2 \
        --amazonec2-region=$REGION \
        --amazonec2-vpc-id=$VPC \
        --amazonec2-zone=a \
        --amazonec2-subnet-id=$SUBNET \
        --amazonec2-root-size="16" \
        --engine-install-url="https://releases.rancher.com/install-docker/19.03.9.sh" \
        --amazonec2-security-group="runner-swarm" \
        --amazonec2-open-port 2377 \
        runner-node-$i;
    docker-machine ssh runner-node-$i -- sudo docker swarm leave --force
    i=$((i + 1));
done

# # https://docs.docker.com/engine/swarm/swarm-tutorial/#open-protocols-and-ports-between-the-hosts
SG=$(aws ec2 describe-security-groups \
    --filter Name=group-name,Values=runner-swarm \
    --query SecurityGroups[0].GroupId \
    --output text)
aws ec2 authorize-security-group-ingress --group-id=$SG --protocol=tcp --port=2377 --source-group=$SG
aws ec2 authorize-security-group-ingress --group-id=$SG --protocol=tcp --port=7946 --source-group=$SG
aws ec2 authorize-security-group-ingress --group-id=$SG --protocol=udp --port=7946 --source-group=$SG
aws ec2 authorize-security-group-ingress --group-id=$SG --protocol=tcp --port=4789 --source-group=$SG
aws ec2 authorize-security-group-ingress --group-id=$SG --protocol=udp --port=4789 --source-group=$SG

# # https://docs.docker.com/engine/swarm/swarm-tutorial/#the-ip-address-of-the-manager-machine
IP=$(aws ec2 describe-instances \
    --filter Name=key-name,Values=runner-node-1 Name=instance-state-code,Values=16 \
    --query Reservations[0].Instances[0].PrivateIpAddress \
    --output text);

docker-machine ssh runner-node-1 -- sudo docker swarm init --advertise-addr $IP

TOKEN=$(docker-machine ssh runner-node-1 \
    -- sudo docker swarm join-token -q worker);

i=2;
while [ $i -le $1 ]
do
    echo "docker-machine ssh runner-node-$i -- sudo docker swarm join --token $TOKEN $IP:2377;"
    docker-machine ssh runner-node-$i -- sudo docker swarm join --token=$TOKEN $IP:2377;
    i=$((i + 1));
done

eval $(docker-machine env runner-node-1)
docker stack deploy --compose-file=docker-compose.yml actions

docker service scale actions_runner=$1