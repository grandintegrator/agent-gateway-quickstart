"""A dummy MCP server: canned weather data, two tools, no auth, no state.

It exists so the Agent Gateway demo has an MCP destination to govern. Deploy
it to Cloud Run (see README step 2) and the MCP endpoint is at
https://<service-url>/mcp.

Runs in stateless mode so it can be exercised with a single curl — no
initialize handshake or session header needed:

    curl -sS -X POST https://<service-url>/mcp \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
           "params":{"name":"get_weather","arguments":{"city":"Melbourne"}}}'
"""

import os

from mcp.server.mcpserver import MCPServer

mcp = MCPServer("demo-weather")


@mcp.tool()
def get_weather(city: str) -> dict:
    """Current weather for a city (canned demo data)."""
    return {"city": city, "temperature_c": 22, "conditions": "sunny", "source": "canned demo data"}


@mcp.tool()
def get_forecast(city: str, days: int = 3) -> dict:
    """Multi-day forecast for a city (canned demo data)."""
    days = max(1, min(days, 7))
    return {
        "city": city,
        "forecast": [
            {"day": i + 1, "high_c": 20 + i, "low_c": 11 + i, "conditions": "partly cloudy"}
            for i in range(days)
        ],
        "source": "canned demo data",
    }


if __name__ == "__main__":
    mcp.run(
        transport="streamable-http",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8080")),
        stateless_http=True,  # every request stands alone — easy to demo
        json_response=True,   # plain JSON replies instead of SSE frames
    )
