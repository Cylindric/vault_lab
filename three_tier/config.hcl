disable_mlock = true
api_addr = "http://127.0.0.1:8200"
disable_clustering = true
ui = true

storage "file" {
  path = "./data"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = 1
}
