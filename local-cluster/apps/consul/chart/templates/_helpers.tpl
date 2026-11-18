{{- define "consul.namespace" -}}
{{- default .Release.Namespace .Values.namespace -}}
{{- end -}}

{{- define "consul.chartSourceName" -}}
{{- printf "%s-chart" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "consul.imagePullSecretName" -}}
{{- default (dig "corp" "imagePullSecretName" "" .Values.global) .Values.imagePullSecretName -}}
{{- end -}}
