# GitHub Release Notes Generator

A **copy-paste friendly** shell script that auto-generates professional, contributor-aware release notes from your Git history — **no matter your stack**.

✅ Works with **PHP, Laravel, Vue, Nuxt, React, Python, Go**, or any Git project  
✅ Used to generate this very release!  
✅ Zero runtime dependencies beyond `git`, `curl`, and `jq`  
✅ Pure POSIX shell — runs on Linux, macOS, and in CI

---

## 🚀 How to Use in Your Project

1. **Copy these two files** into your repository:
    - [`generate_release_notes.sh`](generate_release_notes.sh)
    - [`.github/workflows/release.yml`](.github/workflows/release.yml)

2. **Push a tag**:
   ```sh
   git tag -a v1.0.0 -m "Release v1.0.0"
   git push origin v1.0.0

3. **sign of commits** with your username and email
    ```sh
    git commit --author="Nome <Nome@email.com>" -m "Mensagem do commit"

# Contributing

1. Fork the repo
2. Create your feature branch from `dev`
3. Commit your changes
4. Push to your branch
5. Open a **Pull Request to `dev`** (not `main`!)
