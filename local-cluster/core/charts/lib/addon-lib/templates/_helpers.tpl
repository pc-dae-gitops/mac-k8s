{{/*
Helpers shared by the core addon charts, which render HelmReleases for the upstream charts.

Each addon chart is passed the cluster settings from the cluster-config ConfigMap as values, see the HelmReleases in
core/charts/<cluster type>/release.yaml and core/charts/common/release.yaml:

  clusterType:         k8s or crc (OpenShift Local)
  mirrorRegistry:      registry mirroring the upstream registries, image paths are unchanged, i.e. the mirror
                       serves docker.io/hashicorp/vault as <mirrorRegistry>/hashicorp/vault
  imagePullSecretName: docker-registry secret used to pull images, setup.sh creates it in each addon namespace
  proxy:               "true" if a proxy is needed to access the internet, setup.sh creates the proxy-config
                       ConfigMap, keys HTTP_PROXY, HTTPS_PROXY and NO_PROXY, in each addon namespace
  certs:               "true" if additional root CAs are needed, i.e. Zscaler, setup.sh creates the custom-ca
                       ConfigMap, key ca-bundle.crt, in each addon namespace

The addon namespaces are listed in resources/<cluster type>-local-ca-namespaces.txt
*/}}

{{- define "addon.isOpenShift" -}}
{{- if eq (toString .Values.clusterType) "crc" }}true{{ end -}}
{{- end -}}

{{- define "addon.proxyEnabled" -}}
{{- if eq (toString .Values.proxy) "true" }}true{{ end -}}
{{- end -}}

{{- define "addon.certsEnabled" -}}
{{- if eq (toString .Values.certs) "true" }}true{{ end -}}
{{- end -}}

{{/*
Registry to pull an image from, the mirror if set, otherwise the image's upstream registry
Usage: include "addon.registry" (list . "docker.io")
*/}}
{{- define "addon.registry" -}}
{{- $ctx := index . 0 -}}
{{- default (index . 1) $ctx.Values.mirrorRegistry -}}
{{- end -}}

{{/*
Lists, rendered as YAML, "[]" if not required
*/}}

{{- define "addon.imagePullSecrets" -}}
{{- if .Values.imagePullSecretName -}}
- name: {{ .Values.imagePullSecretName }}
{{- else -}}
[]
{{- end -}}
{{- end -}}

{{/*
Proxy environment variables, NO_PROXY is extended with the kubernetes api server and cluster local destinations
*/}}
{{- define "addon.proxyEnv" -}}
{{- if include "addon.proxyEnabled" . -}}
- name: HTTP_PROXY
  valueFrom:
    configMapKeyRef:
      name: proxy-config
      key: HTTP_PROXY
- name: HTTPS_PROXY
  valueFrom:
    configMapKeyRef:
      name: proxy-config
      key: HTTPS_PROXY
- name: PROXY_CONFIG_NO_PROXY
  valueFrom:
    configMapKeyRef:
      name: proxy-config
      key: NO_PROXY
- name: NO_PROXY
  value: "$(PROXY_CONFIG_NO_PROXY),$(KUBERNETES_SERVICE_HOST),localhost,127.0.0.1,.svc,.cluster.local"
{{- else -}}
[]
{{- end -}}
{{- end -}}

{{/*
Root CAs, added to the image's trusted certificates, Go reads every file in /etc/ssl/certs
*/}}
{{- define "addon.caVolumes" -}}
{{- if include "addon.certsEnabled" . -}}
- name: custom-ca
  configMap:
    name: custom-ca
{{- else -}}
[]
{{- end -}}
{{- end -}}

{{- define "addon.caVolumeMounts" -}}
{{- if include "addon.certsEnabled" . -}}
- name: custom-ca
  mountPath: /etc/ssl/certs/custom-ca.crt
  subPath: ca-bundle.crt
  readOnly: true
{{- else -}}
[]
{{- end -}}
{{- end -}}
