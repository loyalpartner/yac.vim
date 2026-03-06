#pragma once
#include <string>

#define MAX_USERS 100
#define MAKE_ID(x) ((x) + 1000)

namespace app {

enum class Color {
    Red,
    Green,
    Blue
};

typedef unsigned int UserId;

struct Point {
    int x;
    int y;
};

class User {
public:
    User(UserId id, const std::string& name);
    std::string getName() const;
    UserId getId() const;

private:
    UserId m_id;
    std::string m_name;
};

template<typename T>
class Container {
public:
    void add(const T& item);
    T get(int index) const;
private:
    T* m_data;
    int m_size;
};

void processUser(const User& user);

} // namespace app
