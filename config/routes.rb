Rails.application.routes.draw do
  # MCPエンドポイント。Streamable HTTP は単一エンドポイントへの POST が基本
  post "/mcp", to: "mcp#handle"
end
