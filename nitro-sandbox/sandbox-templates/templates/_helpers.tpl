{{/*
Same label helpers as kata/sandbox-templates, so `kubectl get pods
-l app.kubernetes.io/name=agent-sandbox` lists the coders of every substrate.
*/}}

{{- define "agent-sandbox.labels" -}}
app.kubernetes.io/name: agent-sandbox
app.kubernetes.io/part-of: open-agent-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "agent-sandbox.selectorLabels" -}}
app.kubernetes.io/name: agent-sandbox
{{- end -}}

{{- define "agent-sandbox.namespace" -}}
{{- default "agent-sandbox-system" .Values.namespace -}}
{{- end -}}
