use std::collections::HashMap;

pub fn add(left: u64, right: u64) -> u64 {
    left + right
}

pub fn test_completion() {
    // 测试点1: std模块补全 - 在第8行字符18位置 (std:: 后面)
    let mut vec = Vec::new();
    vec.push(1); // 测试方法补全，完整的调用
    
    // 测试点2: 本地变量补全 
    let my_variable = "hello";
    let my_other_var = 42;
    // 输入 my 后应该补全为 my_variable 或 my_other_var
    println!("{} {}", my_variable, my_other_var); // Use the variables
    
    // 测试点3: 结构体方法补全
    let mut map = HashMap::new();
    map.insert("key", "value"); // 在点后应该显示insert, get, contains_key等方法
    let _ = map.get("key"); // Use the map to avoid warnings
    
    // 测试点4: 函数参数补全
    let result = test_function("test".to_string()); // 应该补全函数名
    
    // 测试点5: 类型补全
    let x: u32 = 42; // 应该补全为u8, u16, u32, u64, usize等
    println!("Result: {} x: {}", result, x); // Use the variables
}

pub fn test_function(param: String) -> i32 {
    param.len() as i32
}

pub struct TestStruct {
    pub field1: String,
    pub field2: i32,
}

impl TestStruct {
    pub fn new() -> Self {
        TestStruct {
            field1: String::new(),
            field2: 0,
        }
    }
    
    pub fn get_field1(&self) -> &String {
        &self.field1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        let result = add(2, 2);
        assert_eq!(result, 4);
    }
}
