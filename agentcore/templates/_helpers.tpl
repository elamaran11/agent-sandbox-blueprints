{{/* Same capability labels as the Lambda chart; component identifies the substrate. */}}
{{- define "agentcore.labels" -}}
app.kubernetes.io/name: agent-sandbox
app.kubernetes.io/component: agentcore
app.kubernetes.io/part-of: open-agent-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "agentcore.namespace" -}}
{{- default "agent-sandbox-system" .Values.namespace -}}
{{- end -}}
