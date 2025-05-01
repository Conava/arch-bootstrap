# 1. sync keys + base tools
sudo pacman -Sy --needed git curl base-devel

# 2. (optional) speed up AUR builds later
sudo pacman -Sy --needed --noconfirm fakeroot binutils gcc

# 3. Run the installer 
# clone → run master utility  (--all = everything in one go)
curl -sL https://raw.githubusercontent.com/Conava/arch-bootstrap/main/bootstrap.sh | bash -s -- --all
