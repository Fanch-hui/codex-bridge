package gateway

const arkHost = "ark.cn-beijing.volces.com"

var arkIncludes = map[string]bool{"reasoning.encrypted_content": true}

func includeTaken(host, v string) bool {
	return host != arkHost || arkIncludes[v]
}
