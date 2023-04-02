# Versões
KIND_VERSION ?= 0.18.0
GIROPOPS_SENHAS_VERSION ?= 1.0
GIROPOPS_LOCUST_VERSION ?= 1.0
KUBECTL_VERSION ?= v1.26.3
ISTIO_VERSION ?= 1.17.1

# Definir o sistema operacional
OS = $(shell uname -s)

# Tarefas principais
.PHONY: all
all: docker kind kubectl metallb kube-prometheus istio kiali argocd giropops-senhas giropops-locust 

ifeq ($(OS),Linux)
  DOCKER_COMMAND = sudo curl -fsSL https://get.docker.com | bash
  KIND_COMMAND = curl -Lo ./kind "https://kind.sigs.k8s.io/dl/$(KIND_VERSION)/kind-linux-amd64 && chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind
  KUBECTL_COMMAND = curl -LO https://storage.googleapis.com/kubernetes-release/release/$(KUBECTL_VERSION)/bin/linux/amd64/kubectl && chmod +x ./kubectl && sudo mv ./kubectl /usr/local/bin/
else ifeq ($(OS),Darwin)
  DOCKER_COMMAND = brew install docker
  KIND_COMMAND = brew install kind
  KUBECTL_COMMAND = brew install kubectl
  COLIMA_COMMAND = brew install colima
  SED_COMMAND = brew install gnu-sed
else
  $(error Unsupported operating system: $(OS))
endif

# Instalação do Docker
.PHONY: docker
docker:
	@echo "Instalando o Docker..."
	@command -v docker >/dev/null 2>&1 || $(DOCKER_COMMAND)
ifeq ($(OS),Darwin)
	@echo "Instalando o Colima..."
	@command -v colima >/dev/null 2>&1 || $(COLIMA_COMMAND)
	@echo "Aguardando Colima estar disponível..."
	@while ! command -v colima >/dev/null 2>&1; do \
		sleep 1; \
	done
	colima start
	@echo "Colima iniciado com sucesso!"
endif
	@echo "Docker instalado com sucesso!"

# Instalação do Kind
.PHONY: kind
kind:
	@echo "Instalando o Kind..."
	@command -v kind >/dev/null 2>&1 || $(KIND_COMMAND)
	@if [ -z "$$(kind get clusters | grep kind-linuxtips)" ]; then kind create cluster --name kind-linuxtips --config kind-config/kind-cluster-3-nodes.yaml; fi
	@echo "Kind instalado com sucesso!"

# Instalação do kubectl
.PHONY: kubectl
kubectl:
	@echo "Instalando o kubectl..."
	@command -v kubectl >/dev/null 2>&1 || $(KUBECTL_COMMAND)
	@echo "Kubectl instalado com sucesso!"

# Login no ArgoCD
.PHONY: argo_login
argo_login:
	$(eval SENHA := $(shell kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d))
	@echo "Senha do ArgoCD: ${SENHA}"
	@nohup kubectl port-forward svc/argocd-server -n argocd --address 0.0.0.0 8080:443 &
	@sleep 2
	@argocd login localhost:8080 --insecure --username admin --password $(SENHA)
	@echo "ArgoCD login realizado com sucesso!"

# Adiciona o cluster ao ArgoCD
.PHONY: add_cluster
add_cluster:
ifeq ($(OS),Linux)
	$(eval IP_K8S_API_ENDPOINT := $(shell kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}' | head -n 1))
	$(eval CLUSTER := $(shell kubectl config current-context))
	$(eval PORT_ENDPOINT := $(shell kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].ports[0].port}'))
	$(eval IP_K8S_IP := $(shell kubectl cluster-info | awk '{print $$7}' | head -n 1 | sed 's/\x1b\[[0-9;]*m//g' | sed 's/https:\/\///g'))
	@sed -i "s/https:\/\/$(IP_K8S_IP)/https:\/\/$(IP_K8S_API_ENDPOINT):6443/g" ~/.kube/config
else ifeq ($(OS),Darwin)
	$(eval IP_K8S_API_ENDPOINT := $(shell kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}' | head -n 1))
	$(eval CLUSTER := $(shell kubectl config current-context))
	$(eval PORT_ENDPOINT := $(shell kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].ports[0].port}'))
	$(eval IP_K8S_IP := $(shell kubectl cluster-info | awk '{print $$7}' | head -n 1 | sed 's/\x1b\[[0-9;]*m//g' | sed 's/https:\/\///g'))
	sed "s/https:\/\/$(IP_K8S_IP)/https:\/\/$(IP_K8S_API_ENDPOINT):6443/g" ~/.kube/config > ~/.kube/config_new && mv ~/.kube/config_new ~/.kube/config
else
	$(error Unsupported operating system)
endif
# Debug
	@echo "IP_K8S_API_ENDPOINT: ${IP_K8S_API_ENDPOINT}"
	@echo "CLUSTER: ${CLUSTER}"
	@echo "PORT_ENDPOINT: ${PORT_ENDPOINT}"
	@echo "IP_K8S_IP: ${IP_K8S_IP}"
# End Debug
	argocd cluster add --insecure -y $(CLUSTER)
	@echo "Cluster adicionado com sucesso!"

# Instalando e configurando o ArgoCD
.PHONY: argocd
argocd:
	@echo "Instalando o ArgoCD e o Giropops-Senhas..."
	if [ -z "$$(kubectl get namespace argocd)" ]; then kubectl create namespace argocd; fi
	kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	curl -sSL -o argocd-$(OS)-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-$(OS)-amd64
	sudo install -m 555 argocd-$(OS)-amd64 /usr/local/bin/argocd
	rm argocd-$(OS)-amd64
	while true; do \
		kubectl wait --for=condition=ready --timeout=10m pod -l app.kubernetes.io/name=argocd-server -n argocd && break; \
	    sleep 3; \
	done
	$(MAKE) argo_login
	$(MAKE) add_cluster
	ps -ef | grep -v "ps -ef" | grep kubectl | grep port-forward | grep argocd-server | awk '{print $$2}' | xargs kill
	kubectl label namespace default istio-injection=enabled
	kubectl label namespace argocd istio-injection=enabled
	@echo "ArgoCD foi instalado com sucesso!"

# Instalando o Giropops-Senhas
.PHONY: giropops-senhas
giropops-senhas:
	nohup kubectl port-forward svc/argocd-server -n argocd --address 0.0.0.0 8080:443 &
	$(eval CLUSTER := $(shell kubectl config current-context))
	sleep 10
	argocd app create giropops-senhas --repo https://github.com/badtuxx/giropops-senhas.git --path giropops-senhas --dest-name $(CLUSTER) --dest-namespace default
	argocd app sync giropops-senhas
	ps -ef | grep -v "ps -ef" | grep kubectl | grep port-forward | grep argocd-server | awk '{print $$2}' | xargs kill
	@echo "Giropops-Senhas foi instalado com sucesso!"

# Instalando o Giropops-Locust
.PHONY: giropops-locust
giropops-locust:
	nohup kubectl port-forward svc/argocd-server -n argocd --address 0.0.0.0 8080:443 &
	$(eval CLUSTER := $(shell kubectl config current-context))
	sleep 5
	argocd app create giropops-locust --repo https://github.com/badtuxx/giropops-senhas.git --path locust --dest-name $(CLUSTER) --dest-namespace default
	argocd app sync giropops-locust
	ps -ef | grep -v "ps -ef" | grep kubectl | grep port-forward | grep argocd-server | awk '{print $$2}' | xargs kill
	@echo "Giropops-Locust foi instalado com sucesso!"

# Instalando o Kube-Prometheus
.PHONY: kube-prometheus
kube-prometheus:
	@echo "Instalando o Kube-Prometheus..."
	git clone https://github.com/prometheus-operator/kube-prometheus || true
	cd kube-prometheus
	kubectl create -f kube-prometheus/manifests/setup --request-timeout=100m
	sleep 5
	kubectl create -f kube-prometheus/manifests/ --request-timeout=100m
	sleep 5
	kubectl wait --for=condition=ready --timeout=300s pod -l app.kubernetes.io/part-of=kube-prometheus -n monitoring
	kubectl apply -f prometheus-config/
	rm -rf kube-prometheus
	kubectl label namespace monitoring istio-injection=enabled
	@echo "Kube-Prometheus foi instalado com sucesso!"

# Instalando o MetalLB
.PHONY: metallb
metallb:
	@echo "Instalando o MetalLB..."
	kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.9/config/manifests/metallb-native.yaml
	while true; do \
		kubectl wait --for=condition=ready --timeout=10m pod -l app=metallb -n metallb-system && break; \
	    sleep 5; \
	done
	kubectl apply -f metallb-config/metallb-config.yaml
	@echo "MetalLB foi instalado com sucesso!"

# Instalando o Istio
.PHONY: istio
istio:
	@echo "Instalando o Istio..."
	curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
	cd istio-${ISTIO_VERSION}
	export PATH=$$PWD/bin:$$PATH
	bash -c "source ~/.bashrc"
	istioctl install --set profile=default -y
	kubectl label namespace default istio-injection=enabled
	kubectl wait --for=condition=ready --timeout=300s pod -l app=istiod -n istio-system
	rm -rf istio-${ISTIO_VERSION}
	@echo "Istio foi instalado com sucesso!"

# Instalando o Kiali
.PHONY: kiali
kiali: 
	@echo "Instalando o Kiali..."
	kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.17/samples/addons/kiali.yaml
	while true; do \
		kubectl wait --for=condition=ready --timeout=10m pod -l app=kiali -n istio-system && break; \
		sleep 5; \
	done
	kubectl apply -f istio-config/
	kubectl rollout restart deployment kiali -n istio-system
	@echo "Kiali foi instalado com sucesso!"

# Removendo o Kind e limpando tudo que foi instalado
.PHONY: clean
clean:
	@echo "Desinstalando o Istio..."
	istioctl x uninstall --purge || true
	@echo "Istio desinstalado com sucesso!"
	@echo "Removendo o cluster do Kind..."
	kind delete cluster --name kind-linuxtips || true
	@echo "Cluster removido com sucesso!"
ifeq ($(OS),Darwin)
	@echo "Encerrando o Colima..."
	@colima stop || true
	@echo "Colima encerrado com sucesso!"
endif
	@echo "Removendo diretórios kube-prometheus..."
	@sudo rm -r kube-prometheus