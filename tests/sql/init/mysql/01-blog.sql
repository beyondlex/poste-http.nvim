-- ============================================================
-- Database: blog
-- ============================================================

CREATE DATABASE IF NOT EXISTS blog CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE blog;

-- Schema

CREATE TABLE categories (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(100) NOT NULL UNIQUE,
    slug        VARCHAR(100) NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE authors (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    username    VARCHAR(50)  NOT NULL UNIQUE,
    email       VARCHAR(255) NOT NULL UNIQUE,
    bio         TEXT,
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE posts (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    author_id   INT NOT NULL COMMENT 'References authors.id',
    category_id INT NOT NULL COMMENT 'References categories.id',
    title       VARCHAR(300) NOT NULL COMMENT 'Post title (SEO)',
    slug        VARCHAR(300) NOT NULL UNIQUE COMMENT 'URL-friendly identifier',
    body        TEXT NOT NULL COMMENT 'Post content in Markdown',
    status      ENUM('draft','published','archived') NOT NULL DEFAULT 'draft' COMMENT 'Publication status',
    published_at TIMESTAMP NULL COMMENT 'When the post was published',
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Record creation timestamp',
    FOREIGN KEY (author_id)   REFERENCES authors(id),
    FOREIGN KEY (category_id) REFERENCES categories(id)
) ENGINE=InnoDB COMMENT='Blog posts with SEO metadata';

CREATE TABLE tags (
    id   INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(50) NOT NULL UNIQUE
) ENGINE=InnoDB;

CREATE TABLE post_tags (
    post_id INT NOT NULL,
    tag_id  INT NOT NULL,
    PRIMARY KEY (post_id, tag_id),
    FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE,
    FOREIGN KEY (tag_id)  REFERENCES tags(id)  ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE comments (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    post_id    INT NOT NULL,
    author     VARCHAR(100) NOT NULL,
    email      VARCHAR(255) NOT NULL,
    body       TEXT NOT NULL,
    approved   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE,
    INDEX idx_comments_post_id (post_id),
    INDEX idx_comments_approved (approved)
) ENGINE=InnoDB;

CREATE INDEX idx_posts_author   ON posts(author_id);
CREATE INDEX idx_posts_category ON posts(category_id);
CREATE INDEX idx_posts_status   ON posts(status);

-- Seed data

INSERT INTO categories (name, slug, description) VALUES
  ('Technology',  'technology',  'Software, hardware, and everything in between'),
  ('Design',      'design',      'UI/UX, graphic design, and visual arts'),
  ('DevOps',      'devops',      'Infrastructure, CI/CD, and operations'),
  ('Career',      'career',      'Professional growth and industry insights');

INSERT INTO authors (username, email, bio) VALUES
  ('alice_dev',   'alice@example.com',   'Full-stack developer, open source enthusiast'),
  ('bob_design',  'bob@example.com',     'Product designer with 10 years experience'),
  ('carol_ops',   'carol@example.com',   'SRE at a fintech startup');

INSERT INTO posts (author_id, category_id, title, slug, body, status, published_at) VALUES
  (1, 1, 'Getting Started with Rust',       'getting-started-with-rust',
   'Rust is a systems programming language focused on safety and performance...', 'published', NOW() - INTERVAL 20 DAY),
  (1, 1, 'Neovim as an IDE',                'neovim-as-an-ide',
   'With the right plugins, Neovim can rival any modern IDE...',                  'published', NOW() - INTERVAL 15 DAY),
  (2, 2, 'Design Systems at Scale',         'design-systems-at-scale',
   'Building and maintaining a design system across multiple product teams...',   'published', NOW() - INTERVAL 10 DAY),
  (3, 3, 'Kubernetes Observability',        'kubernetes-observability',
   'Logs, metrics, and traces: the three pillars of observability...',             'published', NOW() - INTERVAL 7 DAY),
  (1, 1, 'Async Rust in Production',        'async-rust-in-production',
   'Lessons learned running Tokio-based services in production...',                'draft',     NULL),
  (2, 2, 'Color Theory for Developers',     'color-theory-for-developers',
   'Understanding color spaces, contrast ratios, and accessibility...',            'published', NOW() - INTERVAL 3 DAY),
  (3, 3, 'GitOps with ArgoCD',              'gitops-with-argocd',
   'Declarative continuous delivery for Kubernetes using Git as source of truth...','archived',  NOW() - INTERVAL 60 DAY);

INSERT INTO tags (name) VALUES
  ('rust'), ('neovim'), ('lua'), ('design-system'), ('figma'),
  ('kubernetes'), ('docker'), ('prometheus'), ('gitops'), ('accessibility');

INSERT INTO post_tags (post_id, tag_id) VALUES
  (1, 1),
  (2, 2), (2, 3),
  (3, 4), (3, 5),
  (4, 6), (4, 7), (4, 8),
  (5, 1),
  (6, 5), (6, 10),
  (7, 9), (7, 6);

INSERT INTO comments (post_id, author, email, body, approved) VALUES
  (1, 'reader42',    'reader42@mail.com',    'Great intro to Rust! The borrow checker section was especially helpful.',  TRUE),
  (1, 'cpp_dev',     'cpp@mail.com',         'How does Rust compare to C++ for embedded systems?',                        TRUE),
  (2, 'vim_user',    'vim@mail.com',         'I switched from VS Code last year and never looked back.',                  TRUE),
  (2, 'emacs_fan',   'emacs@mail.com',       'Emacs is still better for Lisp editing though :)',                          FALSE),
  (3, 'junior_dev',  'junior@mail.com',      'We are trying to adopt a design system at my company. Any tips?',           TRUE),
  (4, 'sre_pro',     'sre@mail.com',         'We use Grafana + Loki + Tempo for our stack. Works well.',                  TRUE),
  (4, 'newbie',      'newbie@mail.com',      'What is the difference between logging and tracing?',                       FALSE),
  (6, 'a11y_adv',    'a11y@mail.com',        'Glad to see accessibility being discussed. WCAG 2.2 is a must-read.',        TRUE);
