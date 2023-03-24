# Variables
RESOURCE_GROUP="aks-nginx-ingress-controller"
LOCATION="westeurope"
AKS_NAME="aks-nginx-ingress-controller"

# Create a resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create AKS
az aks create --resource-group $RESOURCE_GROUP \
--name $AKS_NAME \
--generate-ssh-keys \
--node-vm-size Standard_B4ms

# Get AKS credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME

#### Use a Nginx Controller ####
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install nginx-ingress ingress-nginx/ingress-nginx \
--namespace ingress-nginx \
--create-namespace \
--set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz 

# Get the public IP of the ingress controller
INGRESS_PUBLIC_IP=$(kubectl get svc nginx-ingress-ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Create a echo server and ingress resource for nginx ingress controller
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: echo

---

apiVersion: v1
kind: Pod
metadata:
  name: echoserver
  namespace: echo
  labels:
    app: echoserver
spec:
  containers:
  - image: k8s.gcr.io/echoserver:1.10
    name: echoserver
    ports:
    - containerPort: 8080
      protocol: TCP

---

apiVersion: v1
kind: Service
metadata:
  name: echoserver
  namespace: echo
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
  name: echo-ingress
  namespace: echo
  annotations:
    kubernetes.io/ingress.class: nginx
spec:
  rules:
  - host: echo.$INGRESS_PUBLIC_IP.nip.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: 
            name: echoserver
            port:
              number: 8080
EOF

kubectl get ingress -n echo

# Try to access the echo server through the ingress controller
curl http://echo.$INGRESS_PUBLIC_IP.nip.io

# Update ingress-controller to use externalTrafficPolicy: Local
helm upgrade nginx-ingress ingress-nginx/ingress-nginx \
--namespace ingress-nginx \
--set controller.service.externalTrafficPolicy=Local

# Try to access the echo server through the ingress controller
curl http://echo.$INGRESS_PUBLIC_IP.nip.io

# Modify the ingress with whilelist source ip
HOME_IP=$(curl -s ifconfig.me)

# Create a Ingress resource for the echo server
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo-ingress
  namespace: echo
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/whitelist-source-range: "$HOME_IP/32"
spec:
  rules:
  - host: echo.$INGRESS_PUBLIC_IP.nip.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: 
            name: echoserver
            port:
              number: 8080

EOF

kubectl describe ingress -n echo