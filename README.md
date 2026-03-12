# LiquidGlassComponents

![LiquidGlassComponents Preview](preview.gif)

A demo project exploring how Apple's Liquid Glass effect might be implemented on iOS, before Apple ships any official API for it.

## What this is

When Apple previewed Liquid Glass at WWDC, I wanted to understand how it works under the hood. This project is my attempt to reverse-engineer and recreate that effect using available (and not-so-available) iOS rendering primitives. It's not a production library, it's an exploration.

The result is a hybrid rendering architecture that combines `CABackdropLayer` for real-time backdrop blur with Metal GPU shaders for refraction, specular highlights, and blob morphing.

## Components

Four components to demonstrate the effect across different interaction patterns:

| Component | Description |
|-----------|-------------|
| `LiquidGlassTabBar` | Tab bar with a morphing glass selection indicator, badges, and context menus |
| `LiquidGlassSwitcher` | Toggle with a glass blob that expands on interaction |
| `LiquidGlassSlider` | Value slider with a morphing glass thumb and fill track |
| `LiquidGlassInputBar` | Message composition bar with independent glass sections |

## The approach

Each component uses a layered rendering stack:

1. **CABackdropLayer** samples and blurs whatever is behind the view in the compositor
2. **Tint overlay** is a semi-transparent color layer over the blur
3. **Metal refraction** distorts pixels at blob edges to simulate glass bending light
4. **Edge highlights** are a static gradient to imply depth and curvature
5. **Content layer** renders icons, labels, and controls on top

The Metal shaders handle the optical properties: refraction via Snell's Law, Fresnel edge glow, specular highlights, chromatic aberration, and SDF blob morphing with smooth-minimum blending. All motion is driven by physics-based spring animation using Verlet integration, which gives the blobs their characteristic squash-and-stretch feel.

## The core problem: there's no clean way to do this

The honest answer to "how do you blur what's behind a view in real time" is: **you use `CABackdropLayer`**, a private API that Apple uses internally for Control Center, sheets, and the dock.

I couldn't find any other approach that achieves a real, live backdrop blur, one that reflects actual content behind the view as it moves and changes. The alternatives I explored all fall short:

- **`UIVisualEffectView`** adds blur but gives you no control over the blur radius, shape, or ability to composite Metal content on top cleanly
- **Manual render-to-texture** lets you snapshot the view behind, but it's a static image, not live
- **CoreImage filters** can't sample the compositor; they operate on already-captured pixel data

`CABackdropLayer` is the only primitive I found that sits inside the compositor and reads live pixels before they hit the screen. Everything else is a workaround.

### The trade-off

Using a private API is a real drawback. Apple can change or remove it at any time, and using it in a submitted App Store app is against the rules. If you're building something for distribution, this approach isn't viable as-is. That said, since Apple is actively building Liquid Glass into their own OS, there's a reasonable chance they'll expose a public API for it at some point, and the rendering architecture here would map cleanly onto whatever that looks like.

For now, this project is intended for learning and experimentation, not shipping.

## Benefits of this approach

Despite the private API dependency, the architecture has some real strengths:

- **Zero-cost blur.** `CABackdropLayer` blur happens in the compositor at essentially no additional CPU cost
- **True backdrop sampling.** The blur reflects live content, not a snapshot
- **Correct optical behavior.** Refraction, Fresnel glow, and chromatic aberration are physically grounded
- **High frame rates.** Metal discards pixels outside blob influence zones, keeping the shader cheap; CADisplayLink-synchronized at 60-120 FPS
- **Physics feel.** Verlet spring integration gives the morphing its characteristic elasticity
- **Compositor efficiency.** IOSurface zero-copy texture sharing between GPU and CPU, triple-buffered command encoding

## Usage

```swift
// Tab Bar
let tabBar = LiquidGlassTabBar()
tabBar.items = [
    LiquidGlassTabItem(icon: UIImage(systemName: "house.fill")!, title: "Home"),
    LiquidGlassTabItem(icon: UIImage(systemName: "magnifyingglass")!, title: "Search"),
    LiquidGlassTabItem(icon: UIImage(systemName: "bell.fill")!, title: "Notifications"),
    LiquidGlassTabItem(icon: UIImage(systemName: "person.fill")!, title: "Profile"),
]
view.addSubview(tabBar)

// Switcher
let switcher = LiquidGlassSwitcher()
view.addSubview(switcher)

// Slider
let slider = LiquidGlassSlider()
view.addSubview(slider)

// Input Bar
let inputBar = LiquidGlassInputBar()
view.addSubview(inputBar)
```

## Configuration

```swift
var config = LiquidGlassConfiguration()
config.blurIntensity = 1.0          // 0-1 blur radius multiplier
config.refractionStrength = 5.0     // edge pixel distortion
config.specularIntensity = 0.8      // highlight brightness (0-1)
config.cornerRadius = 22.0          // glass shape rounding

// Spring animation
config.springMass = 1.0
config.springStiffness = 300.0
config.springDamping = 28.0

tabBar.configuration = config
```

Presets: `.default`, `.subtle`, `.intense`

## Requirements

- iOS 13+
- Xcode 14+
- Metal-capable device. Test on real hardware, the effect won't render in Simulator
- `CABackdropLayer` is a private API; not suitable for App Store distribution

## Accessibility

- VoiceOver labels and hints on all interactive elements
- Respects Reduce Motion, disables animations and Metal rendering
- Badge value announcements

## Project structure

```
LiquidGlassComponents/
├── Core/
│   ├── LiquidGlassConfiguration.swift   # Visual/animation parameters & Metal uniforms
│   ├── SpringAnimator.swift             # Verlet integration physics
│   ├── SquashStretchAnimator.swift      # Velocity-driven deformation
│   ├── MetalRenderer.swift              # Metal pipeline management
│   ├── IOSurfaceTexturePool.swift       # Zero-copy GPU/CPU texture pool
│   └── PrivateAPIs/                     # CABackdropLayer & portal view wrappers
├── Components/
│   ├── LiquidGlassTabBar.swift
│   ├── LiquidGlassSwitcher.swift
│   ├── LiquidGlassSlider.swift
│   └── LiquidGlassInputBar.swift
├── Shaders.metal                        # Fragment/vertex shaders
└── ViewController.swift                 # Demo app
```
