#!/bin/bash

# automating https://docs.valtix.com/userguide/discovery/gcp-vpc-flow-logs/
# And https://docs.valtix.com/userguide/discovery/gcp-dns-log/

#
##  Edit these variables to reflect your GCP environment
PROJECT_NAME=[YOU_RPROJECT_NAME_HERE]
SERVICE_ACCOUNT_EMAIL="YOUR SERVICE ACCOUNT EMAIL"
VALTIX_TENANT_NAME=YOUR_TENANT_NAME

# A region and zone where assets are deployed.  This can be changed later inside the Valtix UI to pull inventory data from different/more regions and zones
REGION=us-east1
ZONE=us-east1-b

# This is the VPC Network to turn on flow logs for (VPC Networks list - https://console.cloud.google.com/networking/networks/list)
VPC_NETWORK_NAME=default

##
#######  End variable editing
##


#
# These can be edited if needed, but usually don't need to be changed.
BUCKET_NAME=valtix_logs
PUBSUB_TOPIC=valtix_topic
PUBSUB_SUBSCRIPTION=valtix_subscription
##########

# additional vars to be used during setup - don't change these
SINK_NAME=$BUCKET_NAME
PROJECT_ID=$PROJECT_NAME
_DNS_POLICY_NAME=valtixdnslogging
_BUCKET_ROLE_NAME=valtix.storage.buckets.role


# Enable APIs needed by Valtix onboarding
# GCP requires you to enable any APIs before they can be called from the gcloud command.
printf "*** Enabling secretmanager, compute, and iam APIs\n\n"
gcloud services enable secretmanager.googleapis.com
gcloud services enable compute.googleapis.com
gcloud services enable iam.googleapis.com
printf "Done. \n"
printf "\n-------------------------------------------------------------\n\n"

# Steps 1-4
printf "*** Enabling flow logs for VPC subnet\n\tNetwork: $VPC_NETWORK_NAME\n\tRegion: $REGION\n\n"
gcloud compute networks subnets update $VPC_NETWORK_NAME --region=$REGION --enable-flow-logs
printf "\n-------------------------------------------------------------\n\n"

printf "*** Enabling DNS logs for VPC subnet\n\tNetwork: $VPC_NETWORK_NAME\n\tRegion: $REGION\n\n"
gcloud dns policies create $_DNS_POLICY_NAME --description="Send DNS logs to Valtix" --networks=$VPC_NETWORK_NAME --enable-logging
printf "\n-------------------------------------------------------------\n\n"


# Create storage bucket - step 5
printf "*** Creating bucket\n\tBucket: $BUCKET_NAME\n\n"
gsutil mb gs://$BUCKET_NAME
printf "\n-------------------------------------------------------------\n\n"

# Prep for step 6-12
printf "*** Grangint service account Storage Object Creator permissions\n\tProject ID: $PROJECT_ID\n\rService Account: $SERVICE_ACCOUNT_EMAIL\n\n"
gcloud projects add-iam-policy-binding $PROJECT_ID \
      --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
      --role="roles/storage.objectCreator"
printf "\n-------------------------------------------------------------\n\n"

# Create Flow log sink - Step 6-12
printf "*** Creating log sink...\n\tSink Name: $SINK_NAME\n\tBucket: $BUCKET_NAME\n\tProject ID: $PROJECT_ID\n\n"
gcloud logging sinks create --description=valtix_logs \
  $SINK_NAME \
  storage.googleapis.com/$BUCKET_NAME \
  --log-filter="logName:(projects/$PROJECT_ID/logs/compute.googleapis.com%2Fvpc_flows)"
printf "\n-------------------------------------------------------------\n\n"

# Create DNS log sink - Step 6-12
printf "*** Creating log sink...\n\tSink Name: $SINK_NAME\n\tBucket: $BUCKET_NAME\n\tProject ID: $PROJECT_ID\n\n"
gcloud logging sinks create --description=valtix_logs \
  $SINK_NAME \
  storage.googleapis.com/$BUCKET_NAME \
  --log-filter="resource.type=\"dns_query\""
printf "\n-------------------------------------------------------------\n\n"


# Create storage role
printf "*** Creating custom Valtix bucket role\n\n"
gcloud iam roles create $_BUCKET_ROLE_NAME \
    --project $PROJECT_ID \
    --title "Valtix Storage Object List & Get role" \
    --stage= $_ROLE_STAGE \
    --description "Valtix Custom Role - storage.buckets.get,storage.objects.get,storage.objects.list" \
    --permissions storage.buckets.get,storage.objects.get,storage.objects.list,storage.buckets.list
printf "\n-------------------------------------------------------------\n\n"

# NOTE:     I combined 2 roles into 1 with all 4 permissions
# Create buckets list role
# printf "Creating custom Valtix bucket role"
# gcloud iam roles create $_BUCKET_LIST_ROLE_NAME \
#     --project $PROJECT_ID \
#     --title "Valtix Storage Bucket List role" \
#     --stage= $_ROLE_STAGE \
#     --description "Valtix Custom Role - storage.buckets.get,storage.objects.get,storage.objects.list" \
#     --permissions storage.buckets.list


printf "*** Adding new role to service account\n"
# gcloud projects add-iam-policy-binding $PROJECT_ID \
gcloud iam service-accounts add-iam-policy-binding $SERVICE_ACCOUNT_EMAIL \
      --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
      --role="projects/$PROJECT_ID/roles/$_BUCKET_ROLE_NAME" \
      --condition="title=the-expression,expression=(resource.type == \"storage.googleapis.com/Bucket\" || resource.type == \"storage.googleapis.com/Object\") && resource.name.startsWith('projects/_/buckets/valtix_logs')"
printf "\n-------------------------------------------------------------\n\n"

# Create topic and subs - Steps 17-24
printf "*** Creating pubsub topic\n\tTopic: $PUBSUB_TOPIC"
gcloud pubsub topics create $PUBSUB_TOPIC
printf "\n-------------------------------------------------------------\n\n"

printf "*** Assigning subscription to topic\n\tSubscriptiont: $PUBSUB_SUBSCRIPTION\n\tTopic: $PUBSUB_TOPIC\n"
gcloud pubsub subscriptions create $PUBSUB_SUBSCRIPTION \
  --topic=$PUBSUB_TOPIC \
  --push-endpoint="https://prod1-webhook.vtxsecurityservices.com:8093/webhook/$VALTIX_TENANT_NAME/gcp/cloudstorage"
printf "\n-------------------------------------------------------------\n\n"

# Create notification - setp 25
printf "*** Creating cloud notification\n"
gsutil notification create -t $PUBSUB_TOPIC -f json gs://$BUCKET_NAME
printf "\n-------------------------------------------------------------\n\n"

printf "Done!\n"

