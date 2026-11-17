{{- define "arc-runners-controller.chartSourceName" -}}
{{- printf "%s-controller-chart" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
