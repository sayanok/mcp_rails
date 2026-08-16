# frozen_string_literal: true

# トランスポート非依存のプロトコル層。パース済みメッセージ(ハッシュ)を受け取り、
# 返すべきレスポンスのハッシュ、または応答不要(notification)ならnilを返す。
# メッセージの運び方(stdio / HTTP)はこのclassは関知しない。
class McpHandler
  # このサーバーが通信できるプロトコルのバージョン
  SUPPORTED_VERSIONS = [ "2025-11-25", "2025-06-18" ].freeze
  SERVER_INFO = { name: "handson-mcp", version: "0.1.0" }.freeze

  # ダミーの商品マスタ。Day 2 では DB の代わりにメモリ上の配列を使う。
  ITEMS = [
    { id: "item-001", name: "ダンボール箱 60サイズ", stock: 120, unit_price: 80 },
    { id: "item-002", name: "ダンボール箱 100サイズ", stock: 40, unit_price: 150 },
    { id: "item-003", name: "プチプチ ロール 300mm", stock: 0, unit_price: 900 },
    { id: "item-004", name: "OPPテープ 48mm 透明", stock: 500, unit_price: 120 }
  ].freeze

  # tools/list で返す tool 定義。 inputSchema は JSON Schema 形式で、
  # クライアントと LLM が引数の形を機械的に把握するための契約。
  TOOLS = [
    {
      name: "search_items",
      description: "商品マスタをキーワードで検索する。商品名の部分一致で探し、商品ID・在庫数・単価を返す。",
      # description: "検索する",
      inputSchema: {
        type: "object",
        properties: {
          keyword: { type: "string", description: "検索キーワード(商品名の一部)" },
          # keyword: { type: "string", description: "キーワード" },
          limit: { type: "integer", description: "返す件数の上限。省略時は5", minimum: 1 }
        },
        required: [ "keyword" ]
      }
    },
    { name: "create_order_draft",
      description: "商品IDと数量を指定して発注ドラフトを作成する。在庫数を超える数量は指定できない。",
      # description: "発注ドラフトを作成する。",
      inputSchema: {
        type: "object",
        properties: {
          item_id: { type: "string", description: "search_items が返す商品ID" },
          quantity: { type: "integer", description: "発注数量", minimum: 1 }
        },
        required: [ "item_id", "quantity" ]
      }
    }
  ].freeze

  # JSON-RPC のプロトコルエラーを表す例外。メインループが rescue して
  # error レスポンスに変換する。
  class ProtocolError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  # 1メッセージを処理する。
  def handle(msg)
    return nil unless msg.key?("id")

    result = route(msg["method"], msg["params"])
    return error_response(msg["id"], -32601, "Method not found: #{msg["method"]}") if result.nil?

    { jsonrpc: "2.0", id: msg["id"], result: result }
  rescue ProtocolError => e
    error_response(msg["id"], e.code, e.message)
  rescue StandardError => e
    log "internal error: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
    error_response(msg["id"], -32603, "Internal error")
  end

  private

  # method の値に応じて処理を振り分け、レスポンスのresultに入れるハッシュを返す
  # 対応していないメソッドの場合は nil を返す(エラー返却はday1後半で実装する)
  def route(method, params)
    case method
    when "initialize"
      handle_initialize(params)
    when "ping"
      # ping への応答は「空のresult」と仕様で定められている
      {}
    when "tools/list"
      { tools: TOOLS }
    when "tools/call"
      handle_tools_call(params)
    end
  end

  def handle_initialize(params)
    requested = params["protocolVersion"]
    {
      # クライアントが要求したバージョンをサポートしていれば採用する
      # サポートしていなければ、サーバーがサポートするバージョンを提示する
      # 提示されたバージョンを受け入れるかどうかはクライアントが判断する
      protocolVersion: SUPPORTED_VERSIONS.include?(requested) ? requested : SUPPORTED_VERSIONS.first,
      # tools を提供すると宣言する。クライアントはこの宣言をみて tools/list を呼ぶ
      capabilities: { tools: {} },
      serverInfo: SERVER_INFO
    }
  end

  # tools/call を処理する。 name で対象 tool を特定し、 arguments を渡す。
  # 未知の tool 名は「メソッドは正しいが params が不正」なので -32602 を返す。
  def handle_tools_call(params)
    name = params["name"]
    args = params["arguments"] || {}

    case name
    when "search_items"
      search_items(args)
    when "create_order_draft"
      create_order_draft(args)
    else
      raise ProtocolError.new(-32602, "Unknown tool: #{name}")
    end
  end

  # tool: search_items。商品名の部分一致で ITEMS を検索する。
  def search_items(args)
    keyword = args["keyword"]
    # inputSchema は契約にすぎず、クライアントが守る保証はないため、サーバー側でも検証する
    unless keyword.is_a?(String) && !keyword.strip.empty?
      raise ProtocolError.new(-32602, "keyword は必須の文字列です")
    end

    limit = args.fetch("limit", 5)
    raise ProtocolError.new(-32602, "limit は1以上の整数です") unless limit.is_a?(Integer) && limit >= 1

    hits = ITEMS.select { |item| item[:name].include?(keyword) }.first(limit)

    { content: [ { type: "text", text: JSON.generate(hits) } ] }
  end

  # tool: create_order_draft。発注ドラフトを作成する(Day2ではメモリ上で完結)、
  # 引数の契約違反は ProtocolError, 業務的な失敗は tool_error で返し分ける。
  def create_order_draft(args)
    item_id = args["item_id"]
    quantity = args["quantity"]

    raise ProtocolError.new(-32602, "item_id は必須の文字列です") unless item_id.is_a?(String)
    raise ProtocolError.new(-32602, "quantity は1以上の整数です") unless quantity.is_a?(Integer) && quantity >= 1

    item = ITEMS.find { |i| i[:id] == item_id }
    if item.nil?
      return tool_error("商品が見つかりません: #{item_id}。 search_itemsで正しい商品IDを確認してください。")
    end
    if quantity > item[:stock]
      return tool_error("在庫不足: #{item[:name]} の在庫は #{item[:stock]}です(要求: #{quantity})。")
    end

    draft = {
      draft_id: "draft-#{item_id}-#{quantity}", # 採番は Day2 では決めうちで代用
      item_id: item_id,
      item_name: item[:name],
      quantity: quantity,
      total_price: item[:unit_price] * quantity
    }
    { content: [ { type: "text", text: JSON.generate(draft) } ] }
  end

  # JSON-RPC のエラーレスポンスを組み立てる。error は result の代わりに入り、
  # 両方を同時に持つレスポンスは仕様違反になる。
  def error_response(id, code, message)
    { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
  end

  # tool の実行失敗を返す。 isError: true の結果は content ごと LLM の会話に入り、
  # LLM がエラー分を読んで方針を修正できる(プロトコルエラーとの最大の違い)。
  def tool_error(message)
    { content: [ { type: "text", text: message } ], isError: true }
  end

  # ログは必ず stderr へ。 stdout は JSON-RPC メッセージ専用のチャネル
  def log(message)
    $stderr.puts "[handson-mcp] #{message}"
  end
end
