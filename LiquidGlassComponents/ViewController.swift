import UIKit

class ViewController: UIViewController, LiquidGlassTabBarDelegate, UIScrollViewDelegate {

    private var tabBar: LiquidGlassTabBar!
    private var scrollView: UIScrollView!
    private var contentView: UIView!

    override func viewDidLoad() {
        super.viewDidLoad()

        setupScrollableBackground()
        setupTabBar()
    }

    private func setupScrollableBackground() {
        // Create scroll view
        scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceVertical = true
        scrollView.delegate = self
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Create content view (tall for scrolling)
        let contentHeight: CGFloat = 2000
        contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            contentView.heightAnchor.constraint(equalToConstant: contentHeight)
        ])

        // Add gradient background
        let gradientLayer = CAGradientLayer()
        gradientLayer.colors = [
            UIColor.systemPurple.cgColor,
            UIColor.systemBlue.cgColor,
            UIColor.systemTeal.cgColor,
            UIColor.systemGreen.cgColor,
            UIColor.systemYellow.cgColor,
            UIColor.systemOrange.cgColor,
            UIColor.systemRed.cgColor
        ]
        gradientLayer.locations = [0, 0.15, 0.3, 0.45, 0.6, 0.8, 1]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        gradientLayer.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: contentHeight)
        contentView.layer.insertSublayer(gradientLayer, at: 0)

        // Add decorations
        addDecorations(to: contentView, height: contentHeight)
    }

    private func addDecorations(to container: UIView, height: CGFloat) {
        let colors: [UIColor] = [.systemYellow, .systemOrange, .systemPink, .systemRed, .systemCyan, .white]

        // Add many shapes spread throughout the scrollable area
        for i in 0..<30 {
            let size = CGFloat.random(in: 40...120)
            let x = CGFloat.random(in: 20...(UIScreen.main.bounds.width - size - 20))
            let y = CGFloat.random(in: 50...(height - size - 50))

            let shape = UIView(frame: CGRect(x: x, y: y, width: size, height: size))
            shape.backgroundColor = colors[i % colors.count].withAlphaComponent(0.7)
            shape.layer.cornerRadius = size / 2
            container.addSubview(shape)
        }

        // Add some labels to show scroll position
        for i in 0..<10 {
            let label = UILabel()
            label.text = "Section \(i + 1)"
            label.font = .systemFont(ofSize: 24, weight: .bold)
            label.textColor = .white.withAlphaComponent(0.8)
            label.sizeToFit()
            label.frame.origin = CGPoint(x: 20, y: CGFloat(i) * 200 + 100)
            container.addSubview(label)
        }
    }

    private func setupTabBar() {
        let tabBarHeight: CGFloat = 70

        tabBar = LiquidGlassTabBar()
        tabBar.delegate = self

        // Configure items
        tabBar.items = [
            LiquidGlassTabItem(
                icon: UIImage(systemName: "house.fill")!,
                title: "Home"
            ),
            LiquidGlassTabItem(
                icon: UIImage(systemName: "magnifyingglass")!,
                title: "Search"
            ),
            LiquidGlassTabItem(
                icon: UIImage(systemName: "bell.fill")!,
                title: "Alerts",
                badgeValue: "3"
            ),
            LiquidGlassTabItem(
                icon: UIImage(systemName: "person.fill")!,
                title: "Profile"
            )
        ]

        // Configure appearance
        tabBar.configuration = .default

        // Add tab bar ON TOP of scroll view (not inside it)
        view.addSubview(tabBar)

        // Layout
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tabBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            tabBar.heightAnchor.constraint(equalToConstant: tabBarHeight)
        ])

        // Add bottom content inset so scroll content isn't hidden behind tab bar
        scrollView.contentInset.bottom = tabBarHeight + 20
    }

    // MARK: - LiquidGlassTabBarDelegate

    func tabBar(_ tabBar: LiquidGlassTabBar, didSelectItemAt index: Int) {
        print("Selected tab: \(index)")
    }

    func tabBar(_ tabBar: LiquidGlassTabBar, didDoubleTapItemAt index: Int) {
        print("Double-tapped tab: \(index) - scroll to top")
        scrollView.setContentOffset(.zero, animated: true)
    }

}
