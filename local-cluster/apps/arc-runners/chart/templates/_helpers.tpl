{{- define "arc-runners.namespace" -}}
{{- default .Release.Namespace .Values.namespace -}}
{{- end -}}

{{- define "arc-runners.chartSourceName" -}}
{{- printf "%s-runnerset-chart" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "arc-runners.imagePullSecretName" -}}
{{- default (dig "corp" "imagePullSecretName" "" .Values.global) .Values.imagePullSecretName -}}
{{- end -}}
