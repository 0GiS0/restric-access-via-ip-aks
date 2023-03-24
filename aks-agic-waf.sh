# Variables
RESOURCE_GROUP="aks-agic-waf"
LOCATION="northeurope"
AKS_NAME="aks-with-agic-waf"
APP_GW_NAME="appgw-waf"
APP_GW_SUBNET_NAME="appgw-subnet"
VNET_NAME="aks-vnet"
AKS_SUBNET="aks-subnet"

# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create vnet name
az network vnet create \
--name $VNET_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--address-prefix 10.0.0.0/8 \
--subnet-name $AKS_SUBNET \
--subnet-prefix 10.10.0.0/16

# Create subnet for Application Gateway
az network vnet subnet create \
--name $APP_GW_SUBNET_NAME \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--address-prefix 10.20.0.0/16

# Create a WAF policy
GENERAL_WAF_POLICY="general-waf-policies"
az network application-gateway waf-policy create \
--name $GENERAL_WAF_POLICY \
--resource-group $RESOURCE_GROUP \
--type OWASP \
--version 3.2

# Change WAF policy mode to detection
az network application-gateway waf-policy policy-setting update \
--mode Prevention \
--policy-name $GENERAL_WAF_POLICY \
--resource-group $RESOURCE_GROUP \
--state Enabled

# Create public ip
az network public-ip create \
--resource-group $RESOURCE_GROUP \
--name $APP_GW_NAME-public-ip \
--allocation-method Static \
--sku Standard

# Create Application Gateway
az network application-gateway create \
--name $APP_GW_NAME \
--location $LOCATION \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--subnet $APP_GW_SUBNET_NAME \
--capacity 1 \
--sku WAF_v2 \
--http-settings-cookie-based-affinity Disabled \
--frontend-port 80 \
--http-settings-port 80 \
--http-settings-protocol Http \
--public-ip-address $APP_GW_NAME-public-ip \
--waf-policy $GENERAL_WAF_POLICY \
--priority 1

##### For testing purposes only #####
# Create a virtual machine scale set
# az vmss create \
# --name myvmss \
# --resource-group $RESOURCE_GROUP \
# --image UbuntuLTS \
# --admin-username azureuser \
# --admin-password 'P@ssw0rd1234' \
# --instance-count 2 \
# --vnet-name $VNET_NAME \
# --subnet $AKS_SUBNET \
# --vm-sku Standard_B4ms \
# --upgrade-policy-mode Automatic \
# --app-gateway $APP_GW_NAME \
# --backend-pool-name appGatewayBackendPool

# Install nginx
# az vmss extension set \
# --publisher Microsoft.Azure.Extensions \
# --version 2.0 \
# --name CustomScript \
# --resource-group $RESOURCE_GROUP \
# --vmss-name myvmss \
# --settings '{ "fileUris": ["https://raw.githubusercontent.com/Azure/azure-docs-powershell-samples/master/application-gateway/iis/install_nginx.sh"],"commandToExecute": "./install_nginx.sh" }'

# Create storage account to collect logs from Application Gateway
# STORAGE_ACCOUNT_NAME="applicationgwwaflogs"
# az storage account create \
# --name $STORAGE_ACCOUNT_NAME \
# --resource-group $RESOURCE_GROUP \
# --location $LOCATION \
# --sku Standard_LRS \
# --encryption-services blob

# Configuring diagnostics settings for Application Gateway
# APP_GW_ID=$(az network application-gateway show --name $APP_GW_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)

# Get Azure Storage Account ID
# STORAGE_ACCOUNT_ID=$(az storage account show --name $STORAGE_ACCOUNT_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)

# Configure diagnostics settings
# az monitor diagnostic-settings create --name appgwdiag --resource $APP_GW_ID \
# --logs '[ { "category": "ApplicationGatewayAccessLog", "enabled": true, "retentionPolicy": { "days": 30, "enabled": true } }, { "category": "ApplicationGatewayPerformanceLog", "enabled": true, "retentionPolicy": { "days": 30, "enabled": true } }, { "category": "ApplicationGatewayFirewallLog", "enabled": true, "retentionPolicy": { "days": 30, "enabled": true } } ]' \
# --storage-account $STORAGE_ACCOUNT_ID

# Delete virtual machine scale set
# az vmss delete \
# --name myvmss \
# --resource-group $RESOURCE_GROUP

# Create user identity for the AKS cluster
az identity create --name $AKS_NAME-identity --resource-group $RESOURCE_GROUP
IDENTITY_ID=$(az identity show --name $AKS_NAME-identity --resource-group $RESOURCE_GROUP --query id -o tsv)
IDENTITY_CLIENT_ID=$(az identity show --name $AKS_NAME-identity --resource-group $RESOURCE_GROUP --query clientId -o tsv)

# Get VNET id
VNET_ID=$(az network vnet show --resource-group $RESOURCE_GROUP --name $VNET_NAME --query id -o tsv)

# Assign Network Contributor role to the user identity
az role assignment create --assignee $IDENTITY_CLIENT_ID --scope $VNET_ID --role "Network Contributor"
# Permission granted to your cluster's managed identity used by Azure may take up 60 minutes to populate.

AKS_SUBNET_ID=$(az network vnet subnet show --resource-group $RESOURCE_GROUP --vnet-name $VNET_NAME --name $AKS_SUBNET --query id -o tsv)

# Create AKS cluster and use this existing Application Gateway
az aks create \
--resource-group $RESOURCE_GROUP \
--name $AKS_NAME \
--node-vm-size Standard_B4ms \
--network-plugin azure \
--enable-managed-identity \
--generate-ssh-key \
--enable-addons ingress-appgw \
--appgw-id $APP_GW_ID \
--vnet-subnet-id $AKS_SUBNET_ID \
--assign-identity $IDENTITY_ID

# Get AKS credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME

# Deploy aspnetapp
kubectl create ns aspnetapp

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: aspnetapp
  namespace: aspnetapp
  labels:
    app: aspnetapp
spec:
  containers:
  - image: "mcr.microsoft.com/dotnet/samples:aspnetapp"
    name: aspnetapp-image
    ports:
    - containerPort: 80
      protocol: TCP

---

apiVersion: v1
kind: Service
metadata:
  name: aspnetapp
  namespace: aspnetapp
spec:
  selector:
    app: aspnetapp
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80

---

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: aspnetapp
  namespace: aspnetapp
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
spec:
  rules:
  - http:
      paths:
      - path: /
        backend:
          service:
            name: aspnetapp
            port:
              number: 80
        pathType: Exact
EOF

# Check AGIC logs
kubectl logs $(kubectl get pod -l app=ingress-appgw -o jsonpath='{.items[0].metadata.name}' -n kube-system) -n kube-system


# Test Application Gateway
APP_GW_PUBLIC_IP=$(az network public-ip show \
--resource-group $RESOURCE_GROUP \
--name $APP_GW_NAME-public-ip \
--query [ipAddress] \
--output tsv)

echo http://$APP_GW_PUBLIC_IP

# Create a new WAF Policy for AGIC
WAF_POLICY_AGIC_NAME="waf-policy-agic"

az network application-gateway waf-policy create \
--name $WAF_POLICY_AGIC_NAME \
--resource-group $RESOURCE_GROUP 

# Change WAF policy mode to detection
az network application-gateway waf-policy policy-setting update \
--mode Prevention \
--policy-name $WAF_POLICY_AGIC_NAME \
--resource-group $RESOURCE_GROUP \
--state Enabled

# Create a custom rule to deny all
az network application-gateway waf-policy custom-rule create \
--action Block \
--name DenyAll \
--policy-name  $WAF_POLICY_AGIC_NAME \
--priority 20 \
--resource-group $RESOURCE_GROUP \
--rule-type MatchRule

# Create a custom rule to allow access only from my home IP
az network application-gateway waf-policy custom-rule create \
--action Allow \
--name AllowOnlyFromHome \
--policy-name  $WAF_POLICY_AGIC_NAME \
--priority 10 \
--resource-group $RESOURCE_GROUP \
--rule-type MatchRule

# Create the condition for the custom rule
az network application-gateway waf-policy custom-rule match-condition add \
--policy-name $WAF_POLICY_AGIC_NAME \
--resource-group $RESOURCE_GROUP \
--name AllowOnlyFromHome \
--match-variable RemoteAddr \
--operator IPMatch \
--values "$(curl ifconfig.me)"

# Get Waf Policy ID
WAF_POLICY_ID=$(az network application-gateway waf-policy show --name $WAF_POLICY_AGIC_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)

# Deploy echoserver
kubectl create ns echoserver

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: echoserver
  namespace: echoserver
  labels:
    app: echoserver
spec:
  containers:
  - image: k8s.gcr.io/echoserver:1.10
    name: aspnetapp-image
    ports:
    - containerPort: 8080
      protocol: TCP

---

apiVersion: v1
kind: Service
metadata:
  name: echoserver
  namespace: echoserver
spec:
  selector:
    app: echoserver
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080

---

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echoserver
  namespace: echoserver
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
    appgw.ingress.kubernetes.io/override-frontend-port: "8080"
    appgw.ingress.kubernetes.io/waf-policy-for-path: "$WAF_POLICY_ID"
spec:
  rules:
  - http:
      paths:
      - path: /
        backend:
          service:
            name: echoserver
            port:
              number: 8080
        pathType: Exact
EOF

# Check AGIC logs
kubectl logs $(kubectl get pod -l app=ingress-appgw -o jsonpath='{.items[0].metadata.name}' -n kube-system) -n kube-system

curl http://$APP_GW_PUBLIC_IP:8080