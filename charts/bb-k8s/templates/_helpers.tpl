{{- define "bb-k8s.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "bb-k8s.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "bb-k8s.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "bb-k8s.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
app.kubernetes.io/name: {{ include "bb-k8s.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "bb-k8s.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bb-k8s.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "bb-k8s.image" -}}
{{- if .Values.image.digest -}}
{{ printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else -}}
{{ printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end -}}
{{- end }}

{{- define "bb-k8s.bbClaimName" -}}
{{- if .Values.persistence.bb.existingClaim -}}
{{- .Values.persistence.bb.existingClaim -}}
{{- else -}}
{{- printf "bb-data-%s" (include "bb-k8s.fullname" .) -}}
{{- end -}}
{{- end }}

{{- define "bb-k8s.codexClaimName" -}}
{{- if .Values.persistence.codex.existingClaim -}}
{{- .Values.persistence.codex.existingClaim -}}
{{- else -}}
{{- printf "codex-data-%s" (include "bb-k8s.fullname" .) -}}
{{- end -}}
{{- end }}
