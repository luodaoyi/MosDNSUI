package main

import (
	_ "embed"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

// 嵌入静态文件
//
//go:embed index.html
var indexHTML string

// 配置
var (
	MOSDNS_ADMIN_URL   = getEnv("MOSDNS_ADMIN_URL", "http://127.0.0.1:9099")
	MOSDNS_METRICS_URL = MOSDNS_ADMIN_URL + "/metrics"
	PORT               = getEnv("FLASK_PORT", "5001") // 保持环境变量名兼容
	HOST               = getEnv("HOST", "0.0.0.0")
)

// 数据结构
type CacheMetrics struct {
	QueryTotal   float64 `json:"query_total"`
	HitTotal     float64 `json:"hit_total"`
	LazyHitTotal float64 `json:"lazy_hit_total"`
	HitRate      string  `json:"hit_rate"`
	LazyHitRate  string  `json:"lazy_hit_rate"`
	SizeCurrent  float64 `json:"size_current"`
}

type SystemMetrics struct {
	StartTime      string `json:"start_time,omitempty"`
	CPUTime        string `json:"cpu_time,omitempty"`
	ResidentMemory string `json:"resident_memory,omitempty"`
	HeapIdleMemory string `json:"heap_idle_memory,omitempty"`
	GoVersion      string `json:"go_version"`
	Threads        int    `json:"threads,omitempty"`
	OpenFDs        int    `json:"open_fds,omitempty"`
}

type MetricsResponse struct {
	Caches map[string]CacheMetrics `json:"caches"`
	System SystemMetrics           `json:"system"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

// HTTP 客户端
var httpClient = &http.Client{Timeout: 5 * time.Second}

// 预编译的正则表达式
var patterns = map[string]*regexp.Regexp{
	"cache":            regexp.MustCompile(`mosdns_cache_(\w+)\{tag="([^"]+)"\}\s+([\d.eE+-]+)`),
	"start_time":       regexp.MustCompile(`^process_start_time_seconds\s+([\d.eE+-]+)`),
	"cpu_time":         regexp.MustCompile(`^process_cpu_seconds_total\s+([\d.eE+-]+)`),
	"resident_memory":  regexp.MustCompile(`^process_resident_memory_bytes\s+([\d.eE+-]+)`),
	"heap_idle_memory": regexp.MustCompile(`^go_memstats_heap_idle_bytes\s+([\d.eE+-]+)`),
	"threads":          regexp.MustCompile(`^go_threads\s+(\d+)`),
	"open_fds":         regexp.MustCompile(`^process_open_fds\s+(\d+)`),
	"go_version":       regexp.MustCompile(`go_info\{version="([^"]+)"\}`),
}

// 工具函数
func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

// 从 MosDNS 获取原始 metrics 数据
func fetchMosDNSMetrics() (string, error) {
	resp, err := httpClient.Get(MOSDNS_METRICS_URL)
	if err != nil {
		return "", fmt.Errorf("无法连接到 MosDNS metrics 接口: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("MosDNS metrics 接口返回错误状态: %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("读取 metrics 响应失败: %w", err)
	}

	return string(body), nil
}

// 解析 metrics 文本并格式化为前端需要的 JSON 结构
func parseMetrics(metricsText string) *MetricsResponse {
	data := &MetricsResponse{
		Caches: make(map[string]CacheMetrics),
		System: SystemMetrics{GoVersion: "N/A"},
	}

	lines := strings.Split(metricsText, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parseLine(line, data)
	}

	// 计算命中率并格式化数据
	calculateHitRates(data)
	formatSystemMetrics(data)

	return data
}

// 解析单行 metrics
func parseLine(line string, data *MetricsResponse) {
	// 解析缓存指标
	if matches := patterns["cache"].FindStringSubmatch(line); matches != nil {
		metric, tag, valueStr := matches[1], matches[2], matches[3]
		value, err := strconv.ParseFloat(valueStr, 64)
		if err != nil {
			return
		}

		if _, exists := data.Caches[tag]; !exists {
			data.Caches[tag] = CacheMetrics{}
		}

		cache := data.Caches[tag]
		switch metric {
		case "query_total":
			cache.QueryTotal = value
		case "hit_total":
			cache.HitTotal = value
		case "lazy_hit_total":
			cache.LazyHitTotal = value
		case "size_current":
			cache.SizeCurrent = value
		}
		data.Caches[tag] = cache
		return
	}

	// 解析系统指标
	if matches := patterns["start_time"].FindStringSubmatch(line); matches != nil {
		if value, err := strconv.ParseFloat(matches[1], 64); err == nil {
			data.System.StartTime = time.Unix(int64(value), 0).Format("2006-01-02 15:04:05")
		}
	} else if matches := patterns["cpu_time"].FindStringSubmatch(line); matches != nil {
		if value, err := strconv.ParseFloat(matches[1], 64); err == nil {
			data.System.CPUTime = fmt.Sprintf("%.2f 秒", value)
		}
	} else if matches := patterns["resident_memory"].FindStringSubmatch(line); matches != nil {
		if value, err := strconv.ParseFloat(matches[1], 64); err == nil {
			data.System.ResidentMemory = fmt.Sprintf("%.2f MB", value/1024/1024)
		}
	} else if matches := patterns["heap_idle_memory"].FindStringSubmatch(line); matches != nil {
		if value, err := strconv.ParseFloat(matches[1], 64); err == nil {
			data.System.HeapIdleMemory = fmt.Sprintf("%.2f MB", value/1024/1024)
		}
	} else if matches := patterns["threads"].FindStringSubmatch(line); matches != nil {
		if value, err := strconv.Atoi(matches[1]); err == nil {
			data.System.Threads = value
		}
	} else if matches := patterns["open_fds"].FindStringSubmatch(line); matches != nil {
		if value, err := strconv.Atoi(matches[1]); err == nil {
			data.System.OpenFDs = value
		}
	} else if matches := patterns["go_version"].FindStringSubmatch(line); matches != nil {
		data.System.GoVersion = matches[1]
	}
}

// 计算命中率
func calculateHitRates(data *MetricsResponse) {
	for tag, cache := range data.Caches {
		if cache.QueryTotal > 0 {
			hitRate := (cache.HitTotal / cache.QueryTotal) * 100
			lazyHitRate := (cache.LazyHitTotal / cache.QueryTotal) * 100
			cache.HitRate = fmt.Sprintf("%.2f%%", hitRate)
			cache.LazyHitRate = fmt.Sprintf("%.2f%%", lazyHitRate)
		} else {
			cache.HitRate = "0.00%"
			cache.LazyHitRate = "0.00%"
		}
		data.Caches[tag] = cache
	}
}

// 格式化系统指标
func formatSystemMetrics(data *MetricsResponse) {
	// 已在 parseLine 中完成格式化
}

// 代理请求到 MosDNS 插件
func proxyPluginsRequest(method, subpath string, body io.Reader) (*http.Response, error) {
	targetURL := fmt.Sprintf("%s/plugins/%s", MOSDNS_ADMIN_URL, subpath)

	req, err := http.NewRequest(method, targetURL, body)
	if err != nil {
		return nil, fmt.Errorf("创建代理请求失败: %w", err)
	}

	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("代理请求到 MosDNS 失败 (%s): %w", targetURL, err)
	}

	return resp, nil
}

// HTTP 处理器
func indexHandler(c *gin.Context) {
	c.Header("Content-Type", "text/html; charset=utf-8")
	c.String(http.StatusOK, indexHTML)
}

func statusHandler(c *gin.Context) {
	metricsText, err := fetchMosDNSMetrics()
	if err != nil {
		log.Printf("ERROR: %v", err)
		c.JSON(http.StatusBadGateway, ErrorResponse{Error: err.Error()})
		return
	}

	data := parseMetrics(metricsText)
	c.JSON(http.StatusOK, data)
}

func pluginProxyHandler(c *gin.Context) {
	subpath := c.Param("subpath")
	method := c.Request.Method

	log.Printf("DEBUG: Proxying %s request to -> /plugins/%s", method, subpath)

	var body io.Reader
	if method == "POST" {
		body = c.Request.Body
	}

	resp, err := proxyPluginsRequest(method, subpath, body)
	if err != nil {
		log.Printf("ERROR: %v", err)
		c.String(http.StatusBadGateway, "请求 MosDNS 失败: %v", err)
		return
	}
	defer resp.Body.Close()

	// 复制响应头
	for key, values := range resp.Header {
		for _, value := range values {
			c.Header(key, value)
		}
	}

	// 设置默认 Content-Type
	if resp.Header.Get("Content-Type") == "" {
		c.Header("Content-Type", "text/plain; charset=utf-8")
	}

	// 复制响应体
	c.Status(resp.StatusCode)
	_, err = io.Copy(c.Writer, resp.Body)
	if err != nil {
		log.Printf("ERROR: Failed to copy response body: %v", err)
	}
}

func main() {
	// 设置 Gin 模式
	if os.Getenv("GIN_MODE") == "" {
		gin.SetMode(gin.ReleaseMode)
	}

	// 创建 Gin 路由器
	r := gin.Default()

	// 添加中间件
	r.Use(gin.Logger())
	r.Use(gin.Recovery())

	// 路由设置
	r.GET("/", indexHandler)
	r.GET("/api/mosdns_status", statusHandler)
	r.GET("/plugins/*subpath", pluginProxyHandler)
	r.POST("/plugins/*subpath", pluginProxyHandler)

	// 启动服务器
	address := fmt.Sprintf("%s:%s", HOST, PORT)
	log.Printf("Starting MosDNS UI server on %s", address)
	log.Printf("MosDNS Admin URL: %s", MOSDNS_ADMIN_URL)

	if err := r.Run(address); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}
