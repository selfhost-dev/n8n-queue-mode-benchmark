#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates the queue-mode test workflows (n8n 2.40.7 node versions).
#
#   ruby workflows/build.rb            # writes workflows/*.json
#   CPU_LOOP=20000000 ruby workflows/build.rb
#
#   q1    Webhook -> Code (fixed CPU work) -> Wait 0.5 s (a slow API call) -> Set   [the benchmark]
#   qbin  Webhook (file upload) -> Set (reads the binary's size)                   [binary data in queue mode]
#   qslow Webhook (answers at once) -> Wait 30 s -> Set                             [executions in flight for drills]
#   qoom  Webhook (answers at once) -> Wait 5 s -> Set with a huge expression       [kills the worker that runs it]
require "json"

dir = __dir__
loop_n = Integer(ENV.fetch("CPU_LOOP", "20000000"))

def webhook(path, mode)
  { "name" => "Webhook", "type" => "n8n-nodes-base.webhook", "typeVersion" => 2.1, "position" => [ 0, 0 ],
    "webhookId" => "#{path}-0000-4000-8000-000000000000"[0, 36],
    "parameters" => { "httpMethod" => "POST", "path" => path, "responseMode" => mode, "options" => {} } }
end

def code(name, js, x)
  { "name" => name, "type" => "n8n-nodes-base.code", "typeVersion" => 2, "position" => [ x, 0 ],
    "parameters" => { "jsCode" => js } }
end

def wait(seconds, x)
  { "name" => "Wait", "type" => "n8n-nodes-base.wait", "typeVersion" => 1.1, "position" => [ x, 0 ],
    "webhookId" => "wait-#{x}-0000-4000-8000-000000000000"[0, 36],
    "parameters" => { "amount" => seconds, "unit" => "seconds" } }
end

def set(name, assignments, x)
  { "name" => name, "type" => "n8n-nodes-base.set", "typeVersion" => 3.4, "position" => [ x, 0 ],
    "parameters" => { "mode" => "manual", "options" => {},
                      "assignments" => { "assignments" => assignments.each_with_index.map do |(k, v, t), i|
                        { "id" => "f#{i}", "name" => k, "value" => v, "type" => t }
                      end } } }
end

def chain(nodes)
  nodes.each_cons(2).to_h do |a, b|
    [ a["name"], { "main" => [ [ { "node" => b["name"], "type" => "main", "index" => 0 } ] ] } ]
  end
end

def workflow(name, nodes)
  { "name" => name, "nodes" => nodes, "connections" => chain(nodes), "settings" => { "executionOrder" => "v1" } }
end

cpu_js = <<~JS
  // Fixed CPU work, the same every run: an integer hash loop.
  let h = 0;
  for (let i = 0; i < #{loop_n}; i++) { h = (h * 31 + i) % 1000003; }
  return [{ json: { h } }];
JS

flows = {
  "q1" => workflow("Q1 cpu + wait", [
    webhook("q1", "lastNode"),
    code("CPU work", cpu_js, 220),
    wait(0.5, 440),
    set("Done", [ [ "ok", true, "boolean" ], [ "h", "={{ $('CPU work').item.json.h }}", "number" ] ], 660)
  ]),
  "qbin" => workflow("QBIN binary", [
    webhook("qbin", "lastNode").tap { |w| w["parameters"]["options"] = { "binaryPropertyName" => "data" } },
    # a multipart field `data` arrives as binary key `data0`
    set("Size", [ [ "keys", "={{ Object.keys($binary || {}).join(',') }}", "string" ],
                 [ "bytes", "={{ Object.values($binary || {})[0]?.bytes ?? 'no binary' }}", "string" ],
                 [ "id", "={{ Object.values($binary || {})[0]?.id ?? '' }}", "string" ] ], 220)
  ]),
  "qbin2" => workflow("QBIN2 read binary bytes", [
    webhook("qbin2", "lastNode").tap { |w| w["parameters"]["options"] = { "binaryPropertyName" => "data" } },
    code("Read bytes", <<~JS, 220)
      const key = Object.keys($input.first().binary || {})[0];
      if (!key) return [{ json: { error: 'no binary on the item' } }];
      const meta = $input.first().binary[key];
      const buf = await this.helpers.getBinaryDataBuffer(0, key);
      return [{ json: { key, id: meta.id, metaBytes: meta.bytes, readBytes: buf.length } }];
    JS
  ]),
  "q20" => workflow("Q20 wait 20s", [ webhook("q20", "onReceived"), wait(20, 220), set("Done", [ [ "ok", true, "boolean" ] ], 440) ]),
  "q50" => workflow("Q50 wait 50s", [ webhook("q50", "onReceived"), wait(50, 220), set("Done", [ [ "ok", true, "boolean" ] ], 440) ]),
  "qcred" => workflow("QCRED uses a credential", [
    webhook("qcred", "lastNode"),
    { "name" => "Call with credential", "type" => "n8n-nodes-base.httpRequest", "typeVersion" => 4.2, "position" => [ 220, 0 ],
      "parameters" => { "url" => "http://n8n-main:5678/healthz", "authentication" => "genericCredentialType",
                        "genericAuthType" => "httpBasicAuth", "options" => {} },
      "credentials" => { "httpBasicAuth" => { "id" => "CRED_ID", "name" => "drill-basic" } } }
  ]),
  "qslow" => workflow("QSLOW in flight", [
    webhook("qslow", "onReceived"),
    wait(30, 220),
    set("Done", [ [ "ok", true, "boolean" ] ], 440)
  ]),
  "qoom" => workflow("QOOM worker killer", [
    webhook("qoom", "onReceived"),
    wait(5, 220),
    set("Boom", [ [ "n", "={{ Array.from({ length: 60000000 }, (_, i) => ({ i, s: 'x' + i })).length }}", "number" ] ], 440)
  ])
}

flows.each { |name, wf| File.write(File.join(dir, "#{name}.json"), JSON.pretty_generate(wf) + "\n") }
puts "wrote #{flows.keys.join(', ')} (CPU_LOOP=#{loop_n})"
