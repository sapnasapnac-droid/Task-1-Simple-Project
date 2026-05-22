// =============================================================================
// JSON Placeholder Server
// =============================================================================
// A minimal fake REST API server built on json-server.
// Generates random users and posts using @faker-js/faker, then exposes them
// via standard REST endpoints (/users, /posts, /users/:id, etc.).
// =============================================================================

const jsonServer = require('json-server');
const { faker } = require('@faker-js/faker');

// -----------------------------------------------------------------------------
// Data generation
// -----------------------------------------------------------------------------
// Seed faker for reproducible output (helps tests be deterministic).
faker.seed(42);

function generateUsers(count) {
  const users = [];
  for (let i = 1; i <= count; i++) {
    users.push({
      id: i,
      name: faker.person.fullName(),
      username: faker.internet.userName(),
      email: faker.internet.email(),
      city: faker.location.city()
    });
  }
  return users;
}

function generatePosts(count, userCount) {
  const posts = [];
  for (let i = 1; i <= count; i++) {
    posts.push({
      id: i,
      userId: faker.number.int({ min: 1, max: userCount }),
      title: faker.lorem.sentence(),
      body: faker.lorem.paragraph()
    });
  }
  return posts;
}

function generateDatabase() {
  const userCount = 10;
  const postCount = 20;
  return {
    users: generateUsers(userCount),
    posts: generatePosts(postCount, userCount)
  };
}

// -----------------------------------------------------------------------------
// Server setup
// -----------------------------------------------------------------------------
const server = jsonServer.create();
const router = jsonServer.router(generateDatabase());
const middlewares = jsonServer.defaults();

server.use(middlewares);
server.use(router);

// -----------------------------------------------------------------------------
// Start the server only when this file is run directly (not when required by
// tests). This pattern lets test/app.js import `server` without starting it.
// -----------------------------------------------------------------------------
const PORT = process.env.PORT || 3000;

if (require.main === module) {
  server.listen(PORT, () => {
    console.log(`JSON Placeholder server running on http://localhost:${PORT}`);
    console.log(`Try: http://localhost:${PORT}/users`);
  });
}

module.exports = server;