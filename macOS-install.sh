#!/bin/bash

# Versões
KIND_VERSION="0.18.0"
GIROPOPS_SENHAS_VERSION="1.0"
GIROPOPS_LOCUST_VERSION="1.0"
KUBECTL_VERSION="v1.26.3"
ISTIO_VERSION="1.17.1"

# Definir o sistema operacional
OS=$(uname -s)

# Instalação do Docker
function install_docker() {
  echo "Instalando o Docker..."
  command -v docker >/dev/null 2>&1 || { 
    if [[ "$OS" == "Linux" ]]; then
      sudo curl -fsSL https://get.docker.com | bash
    elif [[ "$OS" == "Darwin" ]]; then
      brew install docker
    else
      echo "Sistema operacional não suportado: $OS"
      exit 1
    fi
  }
  echo "Docker instalado com sucesso!"
}

# Instalação do Kind
function install_kind() {
  echo "Instalando o Kind..."
  command -v kind >/dev/null 2>&1 || {
    if [[ "$OS" == "Linux" ]]; then
      curl -Lo ./kind https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-amd64 && \
      chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind
    elif [[ "$OS" == "Darwin" ]]; then
      brew install kind
    else
      echo "Sistema operacional não suportado: $OS"
      exit 1
    fi
  }
  while ! command -v kind >/dev/null 2>&1; do
    sleep 1
  done
  echo "Kind instalado com sucesso!"
  echo "Criando o cluster..."
  if [ -z "$(kind get clusters | grep kind-linuxtips)" ]; then
    kind create cluster --name kind-linuxtips --config kind-config/kind-cluster-3-nodes.yaml
  fi
  echo "Cluster criado com sucesso!"
}

# Instalação do kubectl
function install_kubectl() {
  echo "Instalando o kubectl..."
  command -v kubectl >/dev/null 2>&1 || {
    if [[ "$OS" == "Linux" ]]; then
      curl -LO https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl && \
      chmod +x ./kubectl && sudo mv ./kubectl /usr/local/bin/
    elif [[ "$OS" == "Darwin" ]]; then
      brew install kubectl
    else
      echo "Sistema operacional não suportado: $OS"
      exit 1
    fi
  }
  echo "Kubectl instalado com sucesso!"
}

# Instalação do ArgoCD
function install_argocd() {
  echo "Instalando o ArgoCD..."
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  curl -sSL -o argocd-darwin-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-darwin-amd64
  sudo install -m 555 argocd-darwin-amd64 /usr/local/bin/argocd
	rm argocd-darwin-amd64
  kubectl wait --for=condition=ready --timeout=10m pod -l app.kubernetes.io/name=argocd-server -n argocd
  echo "ArgoCD instalado com sucesso!"
}

# Login no ArgoCD
function argo_login() {
  SENHA=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d)
  nohup kubectl port-forward svc/argocd-server -n argocd --address 0.0.0.0 8080:443 &
  sleep 2
  argocd login localhost:8080 --insecure --username admin --password "$SENHA"
  echo "ArgoCD login realizado com sucesso!"
}

# Adicionar o cluster no ArgoCD
function argo_add_cluster() {
  IP_K8S_API_ENDPOINT=$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}' | head -n 1)
  CLUSTER=$(kubectl config current-context)
  PORT_ENDPOINT=$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].ports[0].port}')
  IP_K8S_IP=$(kubectl cluster-info | awk '{print $7}' | head -n 1 | sed 's/\x1b\[[0-9;]*m//g' | sed 's/https:\/\///g')
  echo "IP_K8S_API_ENDPOINT: $IP_K8S_API_ENDPOINT"
  echo "CLUSTER: $CLUSTER"
  echo "PORT_ENDPOINT: $PORT_ENDPOINT"
  echo "IP_K8S_IP: $IP_K8S_IP"
  sed "s/https:\/\/$IP_K8S_IP/https:\/\/$IP_K8S_API_ENDPOINT:6443/g" ~/.kube/config > ~/.kube/config_new && mv ~/.kube/config_new ~/.kube/config
  echo "Adicionando o cluster no ArgoCD..."
  argocd cluster add --insecure -y $CLUSTER
  echo "Cluster adicionado com sucesso!"
}

# Configuração do ArgoCD
function argo_config() {
  echo "Configurando o ArgoCD..."
  ps -ef | grep -v "ps -ef" | grep kubectl | grep port-forward | grep argocd-server | awk '{print $$2}' | xargs kill
	kubectl label namespace default istio-injection=enabled
	kubectl label namespace argocd istio-injection=enabled
}

# Instalação Giropops-Senhas
function install_giropops_senhas() {
  echo "Instalando o Giropops-Senhas..."
  nohup kubectl port-forward svc/argocd-server -n argocd --address 0.0.0.0 8080:443 &
  CLUSTER=$(kubectl config current-context)
  sleep 5
  argocd app create giropops-senhas --repo https://github.com/badtuxx/giropops-senhas.git --path giropops-senhas --dest-name $CLUSTER --dest-namespace default
	argocd app sync giropops-senhas
	ps -ef | grep -v "ps -ef" | grep kubectl | grep port-forward | grep argocd-server | awk '{print $2}' | xargs kill
  echo "Giropops-Senhas instalado com sucesso!"
}

# Instalação Giropops-Locust
function install_giropops_locust() {
  echo "Instalando o Giropops-Locust..."
  nohup kubectl port-forward svc/argocd-server -n argocd --address 0.0.0.0 8080:443 &
  CLUSTER=$(kubectl config current-context)
  sleep 5
  argocd app create giropops-locust --repo https://github.com/badtuxx/giropops-senhas.git --path locust --dest-name $CLUSTER --dest-namespace default
	argocd app sync giropops-locust
	ps -ef | grep -v "ps -ef" | grep kubectl | grep port-forward | grep argocd-server | awk '{print $2}' | xargs kill
  echo "Giropops-Locust instalado com sucesso!"
}

# Instalando o Kube-Prometheus
function install_kube_prometheus() {
  echo "Instalando o Kube-Prometheus..."
  git clone https://github.com/prometheus-operator/kube-prometheus || true
	cd kube-prometheus
	kubectl create -f manifests/setup --request-timeout=10m
	sleep 5
	kubectl create -f manifests/ --request-timeout=10m
	sleep 5
	kubectl wait --for=condition=ready --timeout=10m pod -l app.kubernetes.io/part-of=kube-prometheus -n monitoring
  cd ..
	kubectl apply -f /prometheus-config/
	rm -rf /kube-prometheus
	kubectl label namespace monitoring istio-injection=enabled
  echo "Kube-Prometheus instalado com sucesso!"
}

# Instalando o MetalLB
function install_metallb() {
  echo "Instalando o MetalLB..."
	kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.9/config/manifests/metallb-native.yaml
  kubectl wait --for=condition=ready --timeout=10m pod -l app=metallb -n metallb-system
  kubectl apply -f metallb-config/metallb-config.yaml
  echo "MetalLB instalado com sucesso!"
}

# Instalando o Istio
function install_istio() {
  echo "Instalando o Istio..."
  curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
  cd istio-${ISTIO_VERSION}
  export PATH=$PWD/bin:$PATH
  istioctl install --set profile=minimal -y
  kubectl label namespace default istio-injection=enabled
	kubectl wait --for=condition=ready --timeout=300s pod -l app=istiod -n istio-system
  cd ..
  rm -rf istio-${ISTIO_VERSION}
  echo "Istio instalado com sucesso!"
}

# Instalando o Kiali
function install_kiali() {
  echo "Instalando o Kiali..."
  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.17/samples/addons/kiali.yaml
  kubectl wait --for=condition=ready --timeout=10m pod -l app=kiali -n istio-system
  kubectl apply -f /istio-config/
	kubectl rollout restart deployment kiali -n istio-system
  echo "Kiali instalado com sucesso!"
}

# Função principal
function main() {
  echo "Iniciando a instalação do ambiente..."
  install_docker
  install_kind
  install_kubectl
  install_metallb
  install_kube_prometheus
  install_istio
  install_kiali 
  install_argocd
  argo_login
  argo_add_cluster
  argo_config
  install_giropops_senhas
  install_giropops_locust
  echo "Ambiente instalado com sucesso!"
}

# Chamada da função principal
main