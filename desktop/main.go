package main

import (
	"embed"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	app := NewApp()

	err := wails.Run(&options.App{
		Title:  "VoiceInput",
		Width:  1120,
		Height: 720,
		MinWidth:  900,
		MinHeight: 600,
		AssetServer: &assetserver.Options{Assets: assets},
		BackgroundColour: &options.RGBA{R: 246, G: 246, B: 248, A: 1},
		OnStartup:  app.startup,
		OnShutdown: app.shutdown,
		Bind: []interface{}{app},
	})
	if err != nil {
		println("Error:", err.Error())
	}
}
