"""The ADK agent used for the Gemini Enterprise step (and by terraform/).

Two tools, one per gateway verdict:
  - the MCP toolset for the dummy weather server (registered + granted => ALLOWED)
  - fetch_url, a plain HTTPS GET to any host (unregistered => DENIED)

Configuration comes from the environment, set at deploy time:
  MCP_URL   the MCP endpoint, e.g. https://<cloud-run-url>/mcp
  MODEL     Gemini model id (default gemini-2.5-flash)
"""

import os
import urllib.request

from google.adk.agents import LlmAgent
from google.adk.tools.mcp_tool.mcp_session_manager import StreamableHTTPConnectionParams
from google.adk.tools.mcp_tool.mcp_toolset import McpToolset

MCP_URL = os.environ.get("MCP_URL", "https://your-mcp-server.example.com/mcp")
MODEL = os.environ.get("MODEL", "gemini-2.5-flash")


def fetch_url(url: str) -> dict:
    """Fetch a URL with a plain HTTPS GET and return the status and the first 500 characters."""
    try:
        with urllib.request.urlopen(url, timeout=20) as resp:
            return {"url": url, "reached": True, "status": resp.status,
                    "body": resp.read(500).decode(errors="replace")}
    except Exception as exc:
        return {"url": url, "reached": False, "error": f"{type(exc).__name__}: {exc}"[:300]}


root_agent = LlmAgent(
    name="gateway_demo_adk_agent",
    model=MODEL,
    description="Weather assistant whose outbound calls are governed by Agent Gateway.",
    instruction=(
        "You are a weather assistant. For any weather or forecast question you MUST call the "
        "get_weather or get_forecast tool and answer from its result. If the user asks you to "
        "fetch or open a URL, call fetch_url with that exact URL and report the outcome, including "
        "any error verbatim. Keep answers to two sentences."
    ),
    tools=[
        McpToolset(connection_params=StreamableHTTPConnectionParams(url=MCP_URL, timeout=30)),
        fetch_url,
    ],
)
