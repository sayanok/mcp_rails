# Streamable HTTP トランスポート層。stdio 版のserver.rbと同じ役割を
# HTTPで果たす。フレーミングはHTTP(1リクエスト=1メッセージ)が担う。
class McpController < ApplicationController
  # サーバー状態はプロセスで1つ
  HANDLER = McpHandler.new

  def handle
    msg = JSON.parse(request.body.read)
    response_hash = HANDLER.handle(msg)

    if response_hash
      render json: response_hash
    else
      # notification には返すメッセージがない。202 Accepted で受領だけを伝える
      head :accepted
    end
  rescue JSON::ParserError
    # ボディをJSONとして解釈できない = トランスポート層の事故(stdio版と同じ整理)
    render json: { jsonrpc: "2.0", id: nil, error: { code: -32700, message: "Parse error" } }
  end
end
