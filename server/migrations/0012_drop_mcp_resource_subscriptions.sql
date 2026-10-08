-- The MCP SSE stream and resources/subscribe were removed: agents receive
-- events by webhook or catch up with list_food_events.
DROP TABLE mcp_resource_subscriptions;
