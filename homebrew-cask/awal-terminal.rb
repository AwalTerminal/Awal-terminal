cask "awal-terminal" do
  version "0.16.0"
  sha256 "364af7fe2b3d8b43689435ba1cccc3d47568272f2fc617445460b04ffcf0525a"

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
