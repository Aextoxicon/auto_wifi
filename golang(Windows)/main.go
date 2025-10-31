package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"time"
)

const CONFIG_FILE = "./config.json"

type Config struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func loadConfig() Config {
	if _, err := os.Stat(CONFIG_FILE); os.IsNotExist(err) {
		return Config{}
	}
	data, err := ioutil.ReadFile(CONFIG_FILE)
	if err != nil {
		log.Fatalf("无法读取配置文件: %v", err)
	}
	var config Config
	err = json.Unmarshal(data, &config)
	if err != nil {
		log.Fatalf("无法解析配置文件: %v", err)
	}
	return config
}

func saveConfig(config Config) {
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		log.Fatalf("无法序列化配置文件: %v", err)
	}
	err = ioutil.WriteFile(CONFIG_FILE, data, 0644)
	if err != nil {
		log.Fatalf("无法写入配置文件: %v", err)
	}
	fmt.Println("已保存用户密码到~/config.json")
}

func login(username, password string) bool {
	url := fmt.Sprintf("http://192.168.110.100/drcom/login?callback=dr1003&DDDDD=%s&upass=%s&0MKKey=123456&R1=0&R3=0&R6=0&para=00&v6ip=&v=3196",
		username, password)
	client := &http.Client{Timeout: 3 * time.Second}
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		log.Printf("创建登录请求失败: %v", err)
		return false
	}
	req.Header.Set("User-Agent", "curl/7.88.1")
	req.Header.Set("Accept", "*/*")
	req.Header.Set("Connection", "close")

	resp, err := client.Do(req)
	if err != nil {
		log.Printf("登录失败: %v", err)
		return false
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		log.Printf("读取登录响应失败: %v", err)
		return false
	}

	result := resp.StatusCode == 200 && (string(body) == `"result":1` || string(body) == `dr1003({"result":1}`)
	fmt.Printf("登录 %s\n", map[bool]string{true: "Success", false: "Failed"}[result])
	return result
}

// 检测网络状态
func checkNetworkStatus() bool {
	testUrl := "http://www.msftconnecttest.com/connecttest.txt"
	client := &http.Client{Timeout: 1 * time.Second}
	req, err := http.NewRequest("GET", testUrl, nil)
	if err != nil {
		log.Printf("创建网络检测失败: %v", err)
		return false
	}
	req.Header.Set("Cache-Control", "no-cache")

	resp, err := client.Do(req)
	if err != nil {
		log.Printf("网络检测失败: %v", err)
		return false
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		log.Printf("读取网络检测响应失败: %v", err)
		return false
	}

	result := resp.StatusCode == 200 && string(body) == "Microsoft Connect Test"
	fmt.Printf("(Ctrl+C退出脚本)网络状态: %s\n", map[bool]string{true: "OK", false: "Error"}[result])
	return result
}

func main() {
	username := flag.String("u", "", "指定用户名")
	password := flag.String("p", "", "指定密码")
	save := flag.Bool("save", false, "保存用户名和密码到本地配置文件")
	flag.Parse()

	config := loadConfig()
	if *username != "" {
		config.Username = *username
	}
	if *password != "" {
		config.Password = *password
	}

	if *save {
		saveConfig(config)
	}

	if config.Username == "" || config.Password == "" {
		log.Fatal("请通过-u指定用户名-p指定密码，(可选)使用--save保存到本地后再运行此脚本。")
	}

	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		isNetworkOk := checkNetworkStatus()
		if !isNetworkOk {
			fmt.Println("网络异常，尝试登录...")
			login(config.Username, config.Password)
		}
	}
}
