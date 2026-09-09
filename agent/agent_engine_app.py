"""Agent Engine entrypoint: root_agent wrapped in the ADK template.

Agent Engine serves whatever object the entrypoint names, and it must expose
`query`/`stream_query` & co. A bare `LlmAgent` does not — the platform
refuses to start ("Class LlmAgent is missing all methods `query`, ...").
`AdkApp` supplies them (plus managed sessions), and `streaming_agent_run_with_events`
is the operation Gemini Enterprise calls through `:streamQuery`.
"""

try:
    from agentplatform.frameworks.adk import AdkApp        # google-cloud-aiplatform >= 2
except ImportError:  # pragma: no cover
    from vertexai.agent_engines import AdkApp              # google-cloud-aiplatform 1.x

from .agent import root_agent

app = AdkApp(agent=root_agent, enable_tracing=True)
