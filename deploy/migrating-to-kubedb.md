# Installing KubeDB Operator

```
helm repo add appscode https://charts.appscode.com/stable/
helm repo update
helm search appscode/kubedb
helm install appscode/kubedb --name kubedb-operator --version v0.13.0-rc.0 --namespace kube-system
kubectl get crds -l app=kubedb -w
helm install appscode/kubedb-catalog --name kubedb-catalog --version v0.13.0-rc.0 --namespace kube-system
helm upgrade kubedb-catalog appscode/kubedb-catalog --version v0.13.0-rc.0 --namespace kube-system
```
