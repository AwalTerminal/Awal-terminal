cask "awal-terminal" do
  version "0.10.2"
  sha256 "d3cc1b2f702519bdae3e1fd378c3e6baa3791ca4c7ac01e58c777a4e07311e79"

  url "https://github.com/AwalTerminal/Awal-terminal/releases/download/v#{version}/AwalTerminal.zip"
  name "Awal Terminal"
  desc "LLM-native terminal emulator for macOS"
  homepage "https://awalterminal.github.io/Awal-terminal/"

  depends_on macos: ">= :sonoma"

  app "AwalTerminal.app"

  zap trash: [
    "~/.config/awal",
  ]
end
