{{- define "debug-pod.name" -}}
debug-pod
{{- end }}

{{- define "debug-pod.securityContext" -}}
{{- if eq .Values.secContext "ROOT" }}
securityContext:
  privileged: true
  allowPrivilegeEscalation: true
  readOnlyRootFilesystem: false
  runAsUser: 0
  runAsGroup: 0
{{- else }}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
{{- end }}
{{- end }}