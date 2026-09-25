// Synthetic connection data only. Never use customer subscription URLs here.
const realityLink =
    'vless://00000000-0000-4000-8000-000000000001@vpn.example.com:4444'
    '?encryption=none&flow=xtls-rprx-vision&type=tcp&security=reality'
    '&sni=www.example.org&fp=firefox'
    '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef'
    '#%F0%9F%87%AA%F0%9F%87%AA%20Test';

// A synthetic Xray template; never commit a customer configuration.
const xrayFixture = '''
{
  "remarks":"Польша - АвтоБС",
  "routing":{
    "rules":[
      {"type":"field","domain":["domain:example.org","full:mail.example.org","regexp:^api\\\\.example\\\\.org\$","geosite:category-test"],"outboundTag":"direct"},
      {"type":"field","ip":["10.0.0.0/8","geoip:private"],"outboundTag":"direct"},
      {"type":"field","balancerTag":"auto_wifi","network":"tcp,udp"}
    ],
    "balancers":[{"tag":"auto_wifi","selector":["WIFI_"],"fallbackTag":"FALLBACK_"}]
  },
  "outbounds":[
    {"tag":"WIFI_","protocol":"vless","settings":{"vnext":[{"address":"vpn.example.com","port":443,"users":[{"id":"00000000-0000-4000-8000-000000000001","flow":"xtls-rprx-vision"}]}]},
     "streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"www.example.org","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","shortId":"0123456789abcdef","fingerprint":"qq"}}},
    {"tag":"FALLBACK_","protocol":"vless","settings":{"vnext":[{"address":"backup.example.com","port":443,"users":[{"id":"00000000-0000-4000-8000-000000000001"}]}]},
     "streamSettings":{"network":"xhttp","security":"tls"}},
    {"tag":"GRPC_","protocol":"vless","settings":{"vnext":[{"address":"grpc.example.com","port":8443,"users":[{"id":"00000000-0000-4000-8000-000000000001"}]}]},
     "streamSettings":{"network":"grpc","grpcSettings":{"serviceName":"service"},"security":"reality","realitySettings":{"serverName":"www.example.org","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","shortId":"0123456789abcdef","fingerprint":"chrome"}}},
    {"tag":"direct","protocol":"freedom"}
  ]
}
''';
