-- zc override script example (Lua)
-- Usage:
--   zc test -c <config.yaml> --override-script docs/config/examples/override-loyalsoldier-rules.lua
-- Note:
--   `rule-providers.*.path` is used as local cache path.
--   If `url` is set, zc will auto-download missing files and best-effort refresh stale cache by interval.
--
-- Optional args via --override-arg:
--   proxy_group=<name>   default: Proxies
--   ruleset_dir=<path>   default: ./ruleset
--   interval=<seconds>   default: 86400

local proxy_group = "Proxies"
local ruleset_dir = "./ruleset"
local interval = 86400

if input and input.args and input.args.proxy_group and input.args.proxy_group ~= "" then
  proxy_group = input.args.proxy_group
end
if input and input.args and input.args.ruleset_dir and input.args.ruleset_dir ~= "" then
  ruleset_dir = input.args.ruleset_dir
end
if input and input.args and input.args.interval and input.args.interval ~= "" then
  local n = tonumber(input.args.interval)
  if n and n > 0 then
    interval = math.floor(n)
  end
end

local function provider(name, behavior)
  return {
    type = "file",
    behavior = behavior,
    url = "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/" .. name .. ".txt",
    path = ruleset_dir .. "/" .. name .. ".txt",
    interval = interval,
  }
end

return {
  ["rule-providers"] = {
    reject = provider("reject", "domain"),
    icloud = provider("icloud", "domain"),
    apple = provider("apple", "domain"),
    google = provider("google", "domain"),
    proxy = provider("proxy", "domain"),
    direct = provider("direct", "domain"),
    private = provider("private", "domain"),
    gfw = provider("gfw", "domain"),
    ["tld-not-cn"] = provider("tld-not-cn", "domain"),
    telegramcidr = provider("telegramcidr", "ipcidr"),
    cncidr = provider("cncidr", "ipcidr"),
    lancidr = provider("lancidr", "ipcidr"),
    applications = provider("applications", "classical"),
  },
  rules = {
    -- Tailscale direct
    "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
    "IP-CIDR,47.110.89.130/32,DIRECT,no-resolve",
    "DOMAIN-SUFFIX,ts.net,DIRECT",
    "DOMAIN-SUFFIX,tailscale.com,DIRECT",

    -- Default
    "RULE-SET,applications,DIRECT",
    "DOMAIN,clash.razord.top,DIRECT",
    "DOMAIN,yacd.haishan.me,DIRECT",
    "RULE-SET,private,DIRECT",
    "RULE-SET,reject,REJECT",
    "RULE-SET,icloud,DIRECT",
    "RULE-SET,apple,DIRECT",
    "RULE-SET,google," .. proxy_group,
    "RULE-SET,proxy," .. proxy_group,
    "RULE-SET,direct,DIRECT",
    "RULE-SET,lancidr,DIRECT",
    "RULE-SET,cncidr,DIRECT",
    "RULE-SET,telegramcidr," .. proxy_group,
    "GEOIP,LAN,DIRECT",
    "GEOIP,CN,DIRECT",
    "MATCH," .. proxy_group,
  },
}
