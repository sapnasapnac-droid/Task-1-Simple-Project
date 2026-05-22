// =============================================================================
// Integration tests for the JSON Placeholder server
// =============================================================================
// Uses tape (test runner) and supertest (HTTP assertions).
// Tests hit real endpoints and verify response shapes, status codes, and
// behavior — exactly the kind of thing that catches breakage when a
// dependency like json-server gets a behavior-changing update.
// =============================================================================

const test = require('tape');
const request = require('supertest');
const server = require('../index');

// -----------------------------------------------------------------------------
// Users endpoints
// -----------------------------------------------------------------------------

test('GET /users returns a list of users', (t) => {
  request(server)
    .get('/users')
    .expect(200)
    .expect('Content-Type', /json/)
    .end((err, res) => {
      t.error(err, 'no request error');
      t.ok(Array.isArray(res.body), 'response body is an array');
      t.equal(res.body.length, 10, 'returns 10 users');
      t.ok(res.body[0].name, 'first user has a name');
      t.ok(res.body[0].email, 'first user has an email');
      t.end();
    });
});

test('GET /users/1 returns a single user', (t) => {
  request(server)
    .get('/users/1')
    .expect(200)
    .expect('Content-Type', /json/)
    .end((err, res) => {
      t.error(err, 'no request error');
      t.equal(res.body.id, 1, 'returned user has id 1');
      t.ok(res.body.name, 'user has a name');
      t.end();
    });
});

test('GET /users/9999 returns 404 for a missing user', (t) => {
  request(server)
    .get('/users/9999')
    .expect(404)
    .end((err) => {
      t.error(err, 'no request error');
      t.end();
    });
});

// -----------------------------------------------------------------------------
// Posts endpoints
// -----------------------------------------------------------------------------

test('GET /posts returns a list of posts', (t) => {
  request(server)
    .get('/posts')
    .expect(200)
    .expect('Content-Type', /json/)
    .end((err, res) => {
      t.error(err, 'no request error');
      t.ok(Array.isArray(res.body), 'response body is an array');
      t.equal(res.body.length, 20, 'returns 20 posts');
      t.ok(res.body[0].title, 'first post has a title');
      t.ok(res.body[0].userId, 'first post has a userId');
      t.end();
    });
});

test('GET /posts/1 returns a single post', (t) => {
  request(server)
    .get('/posts/1')
    .expect(200)
    .end((err, res) => {
      t.error(err, 'no request error');
      t.equal(res.body.id, 1, 'returned post has id 1');
      t.end();
    });
});

// -----------------------------------------------------------------------------
// Query parameters
// -----------------------------------------------------------------------------

test('GET /posts?userId=1 filters posts by user', (t) => {
  request(server)
    .get('/posts?userId=1')
    .expect(200)
    .end((err, res) => {
      t.error(err, 'no request error');
      t.ok(Array.isArray(res.body), 'response is an array');
      res.body.forEach((post) => {
        t.equal(post.userId, 1, `post ${post.id} belongs to user 1`);
      });
      t.end();
    });
});

// -----------------------------------------------------------------------------
// Unknown routes
// -----------------------------------------------------------------------------

test('GET /nonexistent returns 404', (t) => {
  request(server)
    .get('/nonexistent')
    .expect(404)
    .end((err) => {
      t.error(err, 'no request error');
      t.end();
    });
});